module Futhark.Representation.Kernels.Sizes
  ( SizeClass (..), KernelPath )
  where

import Futhark.Util.Pretty
import Language.Futhark.Core (Name)
import Futhark.Representation.AST.Pretty ()

-- | An indication of which comparisons have been performed to get to
-- this point, as well as the result of each comparison.
type KernelPath = [(Name, Bool)]

-- | The class of some kind of configurable size.  Each class may
-- impose constraints on the valid values.
data SizeClass = SizeThreshold KernelPath
               | SizeGroup
               | SizeNumGroups
               | SizeTile
               | SizeLocalMemory
               -- ^ Likely not useful on its own, but querying the
               -- maximum can be handy.
               deriving (Eq, Ord, Show)

instance Pretty SizeClass where
  ppr (SizeThreshold path) = text $ "threshold (" ++ unwords (map pStep path) ++ ")"
    where pStep (v, True) = pretty v
          pStep (v, False) = '!' : pretty v
  ppr SizeGroup = text "group_size"
  ppr SizeNumGroups = text "num_groups"
  ppr SizeTile = text "tile_size"
  ppr SizeLocalMemory = text "local_memory"
