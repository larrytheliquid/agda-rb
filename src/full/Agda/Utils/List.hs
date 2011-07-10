
{-| Utitlity functions on lists.
-}
module Agda.Utils.List where

import Agda.Utils.TestHelpers
import Agda.Utils.QuickCheck
import Agda.Utils.Tuple

import Text.Show.Functions
import Data.Function
import Data.List
import Data.Maybe
import qualified Data.Set as Set

mhead :: [a] -> Maybe a
mhead []    = Nothing
mhead (x:_) = Just x

type Prefix a = [a]
type Suffix a = [a]

-- | Check if a list has a given prefix. If so, return the list
--   minus the prefix.
maybePrefixMatch :: Eq a => Prefix a -> [a] -> Maybe (Suffix a)
maybePrefixMatch []    rest = Just rest
maybePrefixMatch (_:_) []   = Nothing
maybePrefixMatch (p:pat) (r:rest)
  | p == r    = maybePrefixMatch pat rest
  | otherwise = Nothing

-- | Split a list into sublists. Generalisation of the prelude function
--   @words@.
--
--   > words xs == wordsBy isSpace xs
wordsBy :: (a -> Bool) -> [a] -> [[a]]
wordsBy p xs = yesP xs
    where
	yesP xs = noP (dropWhile p xs)

	noP []	= []
	noP xs	= ys : yesP zs
	    where
		(ys,zs) = break p xs

-- | Chop up a list in chunks of a given length.
chop :: Int -> [a] -> [[a]]
chop _ [] = []
chop n xs = ys : chop n zs
    where (ys,zs) = splitAt n xs

-- | All ways of removing one element from a list.
holes :: [a] -> [(a, [a])]
holes []     = []
holes (x:xs) = (x, xs) : map (id -*- (x:)) (holes xs)

-- | Check whether all elements in a list are distinct from each
-- other. Assumes that the 'Eq' instance stands for an equivalence
-- relation.
distinct :: Eq a => [a] -> Bool
distinct []	= True
distinct (x:xs) = x `notElem` xs && distinct xs

-- | An optimised version of 'distinct'.
--
-- Precondition: The list's length must fit in an 'Int'.

fastDistinct :: Ord a => [a] -> Bool
fastDistinct xs = Set.size (Set.fromList xs) == length xs

prop_distinct_fastDistinct :: [Integer] -> Bool
prop_distinct_fastDistinct xs = distinct xs == fastDistinct xs

-- | Checks if all the elements in the list are equal. Assumes that
-- the 'Eq' instance stands for an equivalence relation.
allEqual :: Eq a => [a] -> Bool
allEqual []       = True
allEqual (x : xs) = all (== x) xs

-- | A variant of 'groupBy' which applies the predicate to consecutive
-- pairs.

groupBy' :: (a -> a -> Bool) -> [a] -> [[a]]
groupBy' _ []           = []
groupBy' p xxs@(x : xs) = grp x $ zipWith (\x y -> (p x y, y)) xxs xs
  where
  grp x ys = (x : map snd xs) : tail
    where (xs, rest) = span fst ys
          tail = case rest of
                   []            -> []
                   ((_, z) : zs) -> grp z zs

prop_groupBy' :: (Bool -> Bool -> Bool) -> [Bool] -> Property
prop_groupBy' p xs =
  classify (length xs - length gs >= 3) "interesting" $
    concat gs == xs
    &&
    and [not (null zs) | zs <- gs]
    &&
    and [and (pairInitTail zs zs) | zs <- gs]
    &&
    (null gs || not (or (pairInitTail (map last gs) (map head gs))))
  where gs = groupBy' p xs
        pairInitTail xs ys = zipWith p (init xs) (tail ys)

-- | @'groupOn' f = 'groupBy' (('==') \`on\` f) '.' 'sortBy' ('compare' \`on\` f)@.

groupOn :: Ord b => (a -> b) -> [a] -> [[a]]
groupOn f = groupBy ((==) `on` f) . sortBy (compare `on` f)

-- | @'extractNthElement' n xs@ gives the @n@-th element in @xs@
-- (counting from 0), plus the remaining elements (preserving order).

extractNthElement' :: Integral i => i -> [a] -> ([a], a, [a])
extractNthElement' n xs = (left, el, right)
  where
  (left, el : right) = genericSplitAt n xs

extractNthElement :: Integral i => i -> [a] -> (a, [a])
extractNthElement n xs = (el, left ++ right)
  where
  (left, el, right) = extractNthElement' n xs

prop_extractNthElement :: Integer -> [Integer] -> Property
prop_extractNthElement n xs =
  0 <= n && n < genericLength xs ==>
    genericTake n rest ++ [elem] ++ genericDrop n rest == xs
  where (elem, rest) = extractNthElement n xs

-- A generalised variant of 'elemIndex'.

genericElemIndex :: (Eq a, Integral i) => a -> [a] -> Maybe i
genericElemIndex x xs =
  listToMaybe $
  map fst $
  filter snd $
  zip [0..] $
  map (== x) xs

prop_genericElemIndex :: Integer -> [Integer] -> Property
prop_genericElemIndex x xs =
  classify (x `elem` xs) "members" $
    genericElemIndex x xs == elemIndex x xs

------------------------------------------------------------------------
-- All tests

tests :: IO Bool
tests = runTests "Agda.Utils.List"
  [ quickCheck' prop_distinct_fastDistinct
  , quickCheck' prop_groupBy'
  , quickCheck' prop_extractNthElement
  , quickCheck' prop_genericElemIndex
  ]
