-- 2010-09-29

module IrrelevantDeclaration where

record Subset (A : Set) (P : A -> Set) : Set where
  constructor _#_
  field
    elem         : A
    .certificate : P elem

postulate
  .irrelevant : {A : Set} -> .A -> A

.certificate : {A : Set}{P : A -> Set} -> (x : Subset A P) -> P (Subset.elem x)
certificate (a # p) = irrelevant p
