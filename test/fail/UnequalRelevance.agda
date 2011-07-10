module UnequalRelevance where

postulate
  A : Set
  f : .A -> A
  g : (A -> A) -> A -> A

-- this should fail because
-- cannot use irrelevant function where relevant is needed
h : A -> A
h = g f  -- error: function types are not equal because one is relevant and the other not