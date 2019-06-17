{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
-- | Simple tool for benchmarking Futhark programs.  Use the @--json@
-- flag for machine-readable output.
module Futhark.CLI.Bench (main) where

import Control.Monad
import Control.Monad.Except
import qualified Data.ByteString.Char8 as SBS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Map as M
import Data.Either
import Data.Maybe
import Data.List
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as T
import System.Console.GetOpt
import System.FilePath
import System.Directory
import System.IO
import System.IO.Temp
import System.Timeout
import System.Process.ByteString (readProcessWithExitCode)
import System.Exit
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Encoding.Internal as JSON
import Text.Printf
import Text.Regex.TDFA

import Futhark.Test
import Futhark.Util (pmapIO)
import Futhark.Util.Options

data BenchOptions = BenchOptions
                   { optBackend :: String
                   , optFuthark :: String
                   , optRunner :: String
                   , optRuns :: Int
                   , optExtraOptions :: [String]
                   , optJSON :: Maybe FilePath
                   , optTimeout :: Int
                   , optSkipCompilation :: Bool
                   , optExcludeCase :: [String]
                   , optIgnoreFiles :: [Regex]
                   , optEntryPoint :: Maybe String
                   , optTuning :: Maybe String
                   }

initialBenchOptions :: BenchOptions
initialBenchOptions = BenchOptions "c" "futhark" "" 10 [] Nothing (-1) False
                      ["nobench", "disable"] [] Nothing (Just "tuning")

-- | The name we use for compiled programs.
binaryName :: FilePath -> FilePath
binaryName = dropExtension

newtype RunResult = RunResult { runMicroseconds :: Int }
data DataResult = DataResult String (Either T.Text ([RunResult], T.Text))
data BenchResult = BenchResult FilePath [DataResult]

-- Intermediate types to help write the JSON instances.
newtype DataResults = DataResults [DataResult]

instance JSON.ToJSON DataResults where
  toJSON (DataResults rs) =
    JSON.object $ map dataResultJSON rs
  toEncoding (DataResults rs) =
    JSON.pairs $ mconcat $ map (uncurry (JSON..=) . dataResultJSON) rs

dataResultJSON :: DataResult -> (T.Text, JSON.Value)
dataResultJSON (DataResult desc (Left err)) =
  (T.pack desc, JSON.toJSON $ show err)
dataResultJSON (DataResult desc (Right (runtimes, progerr))) =
  (T.pack desc, JSON.object
                [("runtimes", JSON.toJSON $ map runMicroseconds runtimes),
                 ("stderr", JSON.toJSON progerr)])

encodeBenchResults :: [BenchResult] -> LBS.ByteString
encodeBenchResults rs =
  JSON.encodingToLazyByteString $ JSON.pairs $ mconcat $ do
  BenchResult prog r <- rs
  return $ T.pack prog JSON..= M.singleton ("datasets" :: T.Text) (DataResults r)

runBenchmarks :: BenchOptions -> [FilePath] -> IO ()
runBenchmarks opts paths = do
  -- We force line buffering to ensure that we produce running output.
  -- Otherwise, CI tools and the like may believe we are hung and kill
  -- us.
  hSetBuffering stdout LineBuffering
  benchmarks <- filter (not . ignored . fst) <$> testSpecsFromPaths paths
  (skipped_benchmarks, compiled_benchmarks) <-
    partitionEithers <$> pmapIO (compileBenchmark opts) benchmarks

  when (anyFailedToCompile skipped_benchmarks) exitFailure

  results <- concat <$> mapM (runBenchmark opts) compiled_benchmarks
  case optJSON opts of
    Nothing -> return ()
    Just file -> LBS.writeFile file $ encodeBenchResults results
  when (anyFailed results) exitFailure

  where ignored f = any (`match` f) $ optIgnoreFiles opts

anyFailed :: [BenchResult] -> Bool
anyFailed = any failedBenchResult
  where failedBenchResult (BenchResult _ xs) =
          any failedResult xs
        failedResult (DataResult _ Left{}) = True
        failedResult _                     = False

anyFailedToCompile :: [SkipReason] -> Bool
anyFailedToCompile = not . all (==Skipped)

data SkipReason = Skipped | FailedToCompile | ReferenceFailed
  deriving (Eq)

compileBenchmark :: BenchOptions -> (FilePath, ProgramTest)
                 -> IO (Either SkipReason (FilePath, [InputOutputs]))
compileBenchmark opts (program, spec) =
  case testAction spec of
    RunCases cases _ _ | "nobench" `notElem` testTags spec,
                         "disable" `notElem` testTags spec,
                         any hasRuns cases ->
      if optSkipCompilation opts
        then do
        exists <- doesFileExist $ binaryName program
        if exists
          then return $ Right (program, cases)
          else do putStrLn $ binaryName program ++ " does not exist, but --skip-compilation passed."
                  return $ Left FailedToCompile
        else do
        putStr $ "Compiling " ++ program ++ "...\n"

        ref_res <- runExceptT $ ensureReferenceOutput futhark "c" program cases
        case ref_res of
          Left err -> do
            putStrLn "Reference output generation failed:\n"
            print err
            return $ Left ReferenceFailed

          Right () -> do
            (futcode, _, futerr) <- liftIO $ readProcessWithExitCode futhark
                                    [optBackend opts, program, "-o", binaryName program] ""

            case futcode of
              ExitSuccess     -> return $ Right (program, cases)
              ExitFailure 127 -> do putStrLn $ "Failed:\n" ++ progNotFound futhark
                                    return $ Left FailedToCompile
              ExitFailure _   -> do putStrLn "Failed:\n"
                                    SBS.putStrLn futerr
                                    return $ Left FailedToCompile
    _ ->
      return $ Left Skipped
  where hasRuns (InputOutputs _ runs) = not $ null runs
        futhark = optFuthark opts

runBenchmark :: BenchOptions -> (FilePath, [InputOutputs]) -> IO [BenchResult]
runBenchmark opts (program, cases) = mapM forInputOutputs $ filter relevant cases
  where forInputOutputs (InputOutputs entry_name runs) = do
          (tuning_opts, tuning_desc) <- determineTuning (optTuning opts) program

          putStr $ "Results for " ++ program' ++ tuning_desc ++ ":\n"
          let opts' = opts { optExtraOptions =
                               optExtraOptions opts ++ tuning_opts }
          BenchResult program' . catMaybes <$>
            mapM (runBenchmarkCase opts' program entry_name pad_to) runs
          where program' = if entry_name == "main"
                           then program
                           else program ++ ":" ++ T.unpack entry_name

        relevant = maybe (const True) (==) (optEntryPoint opts) . T.unpack . iosEntryPoint

        pad_to = foldl max 0 $ concatMap (map (length . runDescription) . iosTestRuns) cases

reportResult :: [RunResult] -> IO ()
reportResult [] =
  print (0::Int)
reportResult results = do
  let runtimes = map (fromIntegral . runMicroseconds) results
      avg = sum runtimes / fromIntegral (length runtimes)
      rel_dev = stddevp runtimes / mean runtimes :: Double
  putStrLn $ printf "%10.2f" avg ++ "μs (avg. of " ++ show (length runtimes) ++
    " runs; RSD: " ++ printf "%.2f" rel_dev ++ ")"

progNotFound :: String -> String
progNotFound s = s ++ ": command not found"

type BenchM = ExceptT T.Text IO

runBenchM :: BenchM a -> IO (Either T.Text a)
runBenchM = runExceptT

io :: IO a -> BenchM a
io = liftIO

runBenchmarkCase :: BenchOptions -> FilePath -> T.Text -> Int -> TestRun
                 -> IO (Maybe DataResult)
runBenchmarkCase _ _ _ _ (TestRun _ _ RunTimeFailure{} _ _) =
  return Nothing -- Not our concern, we are not a testing tool.
runBenchmarkCase opts _ _ _ (TestRun tags _ _ _ _)
  | any (`elem` tags) $ optExcludeCase opts =
      return Nothing
runBenchmarkCase opts program entry pad_to tr@(TestRun _ input_spec (Succeeds expected_spec) _ dataset_desc) =
  -- We store the runtime in a temporary file.
  withSystemTempFile "futhark-bench" $ \tmpfile h -> do
  hClose h -- We will be writing and reading this ourselves.
  input <- getValuesBS dir input_spec
  let getValuesAndBS (SuccessValues vs) = do
        vs' <- getValues dir vs
        bs <- getValuesBS dir vs
        return (LBS.toStrict bs, vs')
      getValuesAndBS SuccessGenerateValues =
        getValuesAndBS $ SuccessValues $ InFile $
        testRunReferenceOutput program entry tr
  maybe_expected <- maybe (return Nothing) (fmap Just . getValuesAndBS) expected_spec
  let options = optExtraOptions opts ++ ["-e", T.unpack entry,
                                         "-t", tmpfile,
                                         "-r", show $ optRuns opts,
                                         "-b"]

  -- Report the dataset name before running the program, so that if an
  -- error occurs it's easier to see where.
  putStr $ "dataset " ++ dataset_desc ++ ": " ++
    replicate (pad_to - length dataset_desc) ' '
  hFlush stdout

  -- Explicitly prefixing the current directory is necessary for
  -- readProcessWithExitCode to find the binary when binOutputf has
  -- no program component.
  let (to_run, to_run_args)
        | null $ optRunner opts = ("." </> binaryName program, options)
        | otherwise = (optRunner opts, binaryName program : options)

  run_res <-
    timeout (optTimeout opts * 1000000) $
    readProcessWithExitCode to_run to_run_args $
    LBS.toStrict input

  fmap (Just . DataResult dataset_desc) $ runBenchM $ case run_res of
    Just (progCode, output, progerr) -> do
      case maybe_expected of
        Nothing ->
          didNotFail program progCode $ T.decodeUtf8 progerr
        Just expected ->
          compareResult program expected =<<
          runResult program progCode output progerr
      runtime_result <- io $ T.readFile tmpfile
      runtimes <- case mapM readRuntime $ T.lines runtime_result of
        Just runtimes -> return $ map RunResult runtimes
        Nothing -> itWentWrong $ "Runtime file has invalid contents:\n" <> runtime_result

      io $ reportResult runtimes
      return (runtimes, T.decodeUtf8 progerr)
    Nothing ->
      itWentWrong $ T.pack $ "Execution exceeded " ++ show (optTimeout opts) ++ " seconds."

  where dir = takeDirectory program


readRuntime :: T.Text -> Maybe Int
readRuntime s = case reads $ T.unpack s of
  [(runtime, _)] -> Just runtime
  _              -> Nothing

didNotFail :: FilePath -> ExitCode -> T.Text -> BenchM ()
didNotFail _ ExitSuccess _ =
  return ()
didNotFail program (ExitFailure code) stderr_s =
  itWentWrong $ T.pack $ program ++ " failed with error code " ++ show code ++
  " and output:\n" ++ T.unpack stderr_s

itWentWrong :: (MonadError T.Text m, MonadIO m) =>
               T.Text -> m a
itWentWrong t = do
  liftIO $ putStrLn $ T.unpack t
  throwError t

runResult :: (MonadError T.Text m, MonadIO m) =>
             FilePath
          -> ExitCode
          -> SBS.ByteString
          -> SBS.ByteString
          -> m (SBS.ByteString, [Value])
runResult program ExitSuccess stdout_s _ =
  case valuesFromByteString "stdout" $ LBS.fromStrict stdout_s of
    Left e   -> do
      let actualf = program `replaceExtension` "actual"
      liftIO $ SBS.writeFile actualf stdout_s
      itWentWrong $ T.pack $ show e <> "\n(See " <> actualf <> ")"
    Right vs -> return (stdout_s, vs)
runResult program (ExitFailure code) _ stderr_s =
  itWentWrong $ T.pack $ program ++ " failed with error code " ++ show code ++
  " and output:\n" ++ T.unpack (T.decodeUtf8 stderr_s)

compareResult :: (MonadError T.Text m, MonadIO m) =>
                 FilePath -> (SBS.ByteString, [Value]) -> (SBS.ByteString, [Value])
              -> m ()
compareResult program (expected_bs, expected_vs) (actual_bs, actual_vs) =
  case compareValues1 actual_vs expected_vs of
    Just mismatch -> do
      let actualf = program `replaceExtension` "actual"
          expectedf = program `replaceExtension` "expected"
      liftIO $ SBS.writeFile actualf actual_bs
      liftIO $ SBS.writeFile expectedf expected_bs
      itWentWrong $ T.pack actualf <> " and " <> T.pack expectedf <>
        " do not match:\n" <> T.pack (show mismatch)
    Nothing ->
      return ()

commandLineOptions :: [FunOptDescr BenchOptions]
commandLineOptions = [
    Option "r" ["runs"]
    (ReqArg (\n ->
              case reads n of
                [(n', "")] | n' >= 0 ->
                  Right $ \config ->
                  config { optRuns = n'
                         }
                _ ->
                  Left $ error $ "'" ++ n ++ "' is not a non-negative integer.")
     "RUNS")
    "Run each test case this many times."
  , Option [] ["backend"]
    (ReqArg (\backend -> Right $ \config -> config { optBackend = backend })
     "PROGRAM")
    "The compiler used (defaults to 'futhark-c')."
  , Option [] ["futhark"]
    (ReqArg (\prog -> Right $ \config -> config { optFuthark = prog })
     "PROGRAM")
    "The binary used for operations (defaults to 'futhark')."
  , Option [] ["runner"]
    (ReqArg (\prog -> Right $ \config -> config { optRunner = prog }) "PROGRAM")
    "The program used to run the Futhark-generated programs (defaults to nothing)."
  , Option "p" ["pass-option"]
    (ReqArg (\opt ->
               Right $ \config ->
               config { optExtraOptions = opt : optExtraOptions config })
     "OPT")
    "Pass this option to programs being run."
  , Option [] ["json"]
    (ReqArg (\file ->
               Right $ \config -> config { optJSON = Just file})
    "FILE")
    "Scatter results in JSON format here."
  , Option [] ["timeout"]
    (ReqArg (\n ->
               case reads n of
                 [(n', "")]
                   | n' < max_timeout ->
                   Right $ \config -> config { optTimeout = fromIntegral n' }
                 _ ->
                   Left $ error $ "'" ++ n ++
                   "' is not an integer smaller than" ++ show max_timeout ++ ".")
    "SECONDS")
    "Number of seconds before a dataset is aborted."
  , Option [] ["skip-compilation"]
    (NoArg $ Right $ \config -> config { optSkipCompilation = True })
    "Use already compiled program."
  , Option [] ["exclude-case"]
    (ReqArg (\s -> Right $ \config ->
                config { optExcludeCase = s : optExcludeCase config })
      "TAG")
    "Do not run test cases with this tag."
  , Option [] ["ignore-files"]
    (ReqArg (\s -> Right $ \config ->
                config { optIgnoreFiles = makeRegex s : optIgnoreFiles config })
      "REGEX")
    "Ignore files matching this regular expression."
  , Option "e" ["entry-point"]
    (ReqArg (\s -> Right $ \config ->
                config { optEntryPoint = Just s })
      "NAME")
    "Only run this entry point."
  , Option [] ["tuning"]
    (ReqArg (\s -> Right $ \config -> config { optTuning = Just s })
    "EXTENSION")
    "Look for tuning files with this extension (defaults: .tuning)."
  , Option [] ["no-tuning"]
    (NoArg $ Right $ \config -> config { optTuning = Nothing })
    "Do not load tuning files."
  ]
  where max_timeout :: Int
        max_timeout = maxBound `div` 1000000

main :: String -> [String] -> IO ()
main = mainWithOptions initialBenchOptions commandLineOptions "options... programs..." $ \progs config ->
  Just $ runBenchmarks config progs

--- The following extracted from hstats package by Marshall Beddoe:
--- https://hackage.haskell.org/package/hstats-0.3

-- | Numerically stable mean
mean :: Floating a => [a] -> a
mean x = fst $ foldl' (\(!m, !n) x' -> (m+(x'-m)/(n+1),n+1)) (0,0) x

-- | Standard deviation of population
stddevp :: (Floating a) => [a] -> a
stddevp xs = sqrt $ pvar xs

-- | Population variance
pvar :: (Floating a) => [a] -> a
pvar xs = centralMoment xs (2::Int)

-- | Central moments
centralMoment :: (Floating b, Integral t) => [b] -> t -> b
centralMoment _  1 = 0
centralMoment xs r = sum (map (\x -> (x-m)^r) xs) / n
    where
      m = mean xs
      n = fromIntegral $ length xs
