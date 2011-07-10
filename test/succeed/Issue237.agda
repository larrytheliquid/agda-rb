
module Issue237 where

data _≡_ {A : Set} (x : A) : A → Set where
  refl : x ≡ x

{-# BUILTIN EQUALITY _≡_  #-}
{-# BUILTIN REFL     refl #-}

data Unit : Set where
  unit : Unit

f : Unit → Unit
f u with u
... | unit = unit

postulate
  eq : ∀ u → f u ≡ unit

foo : Unit → Set₁
foo u rewrite eq u = Set

-- Bug.agda:20,1-25
-- Not implemented: type checking of with application
-- when checking that the expression f u | u has type _35 u
