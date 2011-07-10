-- {-# OPTIONS -v tc.univ:100 -v tc.meta:100 #-}
--{-# OPTIONS -v tc.rec:100 #-}
{-# OPTIONS --universe-polymorphism #-}
-- Andreas, 2011-04-27 universe levels can be made irrelevant
module IrrelevantLevel where

open import Common.Level

postulate 
  Lst : .(i : Level)(A : Set i) -> Set i
  nl  : .(i : Level)(A : Set i) -> Lst i A
  cns : .(i : Level)(A : Set i) -> A -> Lst i A -> Lst i A


data List .(i : Level)(A : Set i) : Set i where
  nil  : List i A
  cons : A -> List i A -> List i A

singleton : .{i : Level}{A : Set i}(a : A) -> List i A
singleton a = cons a nil

record Wrap .(i : Level)(A : Set i) : Set i where
  field
    wrap : A

module M .(i : Level)(A : Set i) where

  data Li : Set i where
    ni : Li
    co : A -> Li -> Li

