------------------------------------------------------------------------
-- Slightly heterogeneous finite maps
------------------------------------------------------------------------

{-# LANGUAGE ExistentialQuantification, GADTs #-}

module IndexedMap
  ( Map
  , empty
  , insert
  , lookup
  , size
  ) where

import qualified Data.Map as Map
import Prelude hiding (lookup)
import IndexedOrd

------------------------------------------------------------------------
-- Hiding indices

-- | Hides the index.

data Wrapped t = forall i. Wrap (t i)

instance IndexedEq t => Eq (Wrapped t) where
  Wrap x == Wrap y = eqToBool (iEq x y)

instance IndexedOrd t => Ord (Wrapped t) where
  compare (Wrap x) (Wrap y) = iCompare x y

-- | A pair consisting of a key and a value.

data Paired k v = forall i. Pair (k i) (v i)

-- | Returns the value component from the pair, if the keys are equal.

cast :: IndexedEq k => k i -> Paired k v -> Maybe (v i)
cast t1 (Pair t2 x) = case iEq t1 t2 of
  Nothing   -> Nothing
  Just Refl -> Just x

------------------------------------------------------------------------
-- Finite map

-- | A finite map containing indexed things.

newtype Map k v = Map (Map.Map (Wrapped k) (Paired k v))

-- | Empty map.

empty :: Map k v
empty = Map Map.empty

-- | Inserts a key and a corresponding value into the map.

insert :: IndexedOrd k => k i -> v i -> Map k v -> Map k v
insert k v (Map m) = Map $ Map.insert (Wrap k) (Pair k v) m

-- | Map lookup. 'Nothing' is returned if the type of the resulting
-- value does not match (according to the 'IndexedEq' instance).

lookup :: IndexedOrd k => k i -> Map k v -> Maybe (v i)
lookup k (Map m) = cast k =<< Map.lookup (Wrap k) m

-- | The size of the map (number of keys).

size :: Map k v -> Int
size (Map m) = Map.size m
