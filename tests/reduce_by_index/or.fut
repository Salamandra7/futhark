-- Test with i32.|.
-- ==
--
-- input  {
--   5
--   [0, 1, 2, 3, 4]
--   [1, 1, 1, 1, 1]
-- }
-- output {
--   [1, 1, 1, 1, 1]
-- }
--
-- input  {
--   5
--   [0, 0, 0, 0, 0]
--   [6, 1, 4, 5, -1]
-- }
-- output {
--   [-1, 0, 0, 0, 0]
-- }
--
-- input  {
--   5
--   [1, 2, 1, 4, 5]
--   [1, 1, 4, 4, 4]
-- }
-- output {
--   [0i32, 5i32, 1i32, 0i32, 4i32]
-- }

let main [m] (n: i32) (is: [m]i32) (image: [m]i32) : [n]i32 =
  reduce_by_index (replicate n 0) (i32.|) 0 is image
