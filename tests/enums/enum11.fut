-- Enum equality.
-- ==
-- input { }
-- output { 2 }

type foobar = #foo | #bar

let f (x : foobar) : foobar = 
  match x
    case #foo -> #bar
    case #bar -> #foo

let main : i32 = if (#foo : foobar) == #bar
                 then 1
                 else if (#bar : foobar) == #bar
                      then 2
                      else 3 
