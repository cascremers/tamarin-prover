{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE ViewPatterns       #-}
-- |
-- Copyright   : (c) 2010-2012 Benedikt Schmidt & Simon Meier
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- This is the public interface for constructing and deconstructing constraint
-- systems. The interface for performing constraint solving provided by
-- "Theory.Constraint.Solver".
module Theory.Constraint.System (
  -- * Constraints
    module Theory.Constraint.System.Constraints

  -- * Constraint systems
  , System

  -- ** Construction
  , emptySystem

  , SystemTraceQuantifier(..)
  , formulaToSystem

  -- ** Node constraints
  , sNodes
  , allKDConcs

  , nodeRule
  , nodeConcNode
  , nodePremNode
  , nodePremFact
  , nodeConcFact
  , resolveNodePremFact
  , resolveNodeConcFact

  -- ** Actions
  , allActions
  , allKUActions
  , unsolvedActionAtoms
  -- FIXME: The two functions below should also be prefixed with 'unsolved'
  , kuActionAtoms
  , standardActionAtoms

  -- ** Edge and chain constraints
  , sEdges
  , unsolvedChains

  -- ** Temporal ordering
  , sLessAtoms

  , rawLessRel
  , rawEdgeRel

  , alwaysBefore
  , isInTrace

  -- ** The last node
  , sLastAtom
  , isLast

  -- ** Equations
  , module Theory.Tools.EquationStore
  , sDistinctions
  , sEqStore
  , sSubst
  , sConjDisjEqs

  -- ** Formulas
  , sFormulas
  , sSolvedFormulas

  -- ** Lemmas
  , sLemmas
  , insertLemmas

  -- ** Keeping track of typing assumptions
  , CaseDistKind(..)
  , sCaseDistKind

  -- ** Goals
  , GoalStatus(..)
  , gsSolved
  , gsLoopBreaker
  , gsNr

  , sGoals
  , sNextGoalNr

  -- * Pretty-printing
  , prettySystem
  , prettyNonGraphSystem

  ) where

import           Prelude                              hiding (id, (.))

import           Data.Binary
import qualified Data.DAG.Simple                      as D
import           Data.DeriveTH
import           Data.List                            (foldl', partition)
import qualified Data.Map                             as M
import           Data.Maybe                           (fromMaybe)
import           Data.Monoid                          (Monoid(..))
import qualified Data.Set                             as S

import           Control.Basics
import           Control.Category
import           Control.DeepSeq

import           Data.Label                           ((:->), mkLabels)
import qualified Extension.Data.Label                 as L

import           Logic.Connectives
import           Theory.Constraint.System.Constraints
import           Theory.Model
import           Theory.Text.Pretty
import           Theory.Tools.EquationStore



------------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------------

-- | Whether we are checking for the existence of a trace satisfiying a the
-- current constraint system or whether we're checking that no traces
-- satisfies the current constraint system.
data SystemTraceQuantifier = ExistsSomeTrace | ExistsNoTrace
       deriving( Eq, Ord, Show )

-- | Case dinstinction kind that are allowed. The order of the kinds
-- corresponds to the subkinding relation: untyped < typed.
data CaseDistKind = UntypedCaseDist | TypedCaseDist
       deriving( Eq )

instance Show CaseDistKind where
    show UntypedCaseDist = "untyped"
    show TypedCaseDist   = "typed"

instance Ord CaseDistKind where
    compare UntypedCaseDist UntypedCaseDist = EQ
    compare UntypedCaseDist TypedCaseDist   = LT
    compare TypedCaseDist   UntypedCaseDist = GT
    compare TypedCaseDist   TypedCaseDist   = EQ

-- | The status of a 'Goal'. Use its 'Semigroup' instance to combine the
-- status info of goals that collapse.
data GoalStatus = GoalStatus
    { _gsSolved :: Bool
       -- True if the goal has been solved already.
    , _gsNr :: Integer
       -- The number of the goal: we use it to track the creation order of
       -- goals.
    , _gsLoopBreaker :: Bool
       -- True if this goal should be solved with care because it may lead to
       -- non-termination.
    }
    deriving( Eq, Ord, Show )

-- | A constraint system.
data System = System
    { _sNodes          :: M.Map NodeId RuleACInst
    , _sEdges          :: S.Set Edge
    , _sLessAtoms      :: S.Set (NodeId, NodeId)
    , _sLastAtom       :: Maybe NodeId
    , _sEqStore        :: EqStore
    , _sDistinctions   :: S.Set Distinction     -- groups of distinct variables
    , _sFormulas       :: S.Set LNGuarded
    , _sSolvedFormulas :: S.Set LNGuarded
    , _sLemmas         :: S.Set LNGuarded
    , _sGoals          :: M.Map Goal GoalStatus
    , _sNextGoalNr     :: Integer
    , _sCaseDistKind   :: CaseDistKind
    }
    -- NOTE: Don't forget to update 'substSystem' and 'conjoinSystem' in
    -- "Constraint.Solver.Reduction" when adding further fields to the
    -- constraint system.
    deriving( Eq, Ord )

$(mkLabels [''System, ''GoalStatus])


-- Further accessors
--------------------

-- | Label to access the free substitution of the equation store.
sSubst :: System :-> LNSubst
sSubst = eqsSubst . sEqStore

-- | Label to access the conjunction of disjunctions of fresh substutitution in
-- the equation store.
sConjDisjEqs :: System :-> Conj (SplitId, S.Set (LNSubstVFresh))
sConjDisjEqs = eqsConj . sEqStore



------------------------------------------------------------------------------
-- Constraint system construction
------------------------------------------------------------------------------

-- | The empty constraint system, which is logically equivalent to true.
emptySystem :: CaseDistKind -> System
emptySystem = System
    M.empty S.empty S.empty Nothing emptyEqStore S.empty
    S.empty S.empty S.empty
    M.empty 0

-- | Returns the constraint system that has to be proven to show that given
-- formula holds in the context of the given theory.
formulaToSystem :: [LNGuarded]           -- ^ Axioms to add
                -> CaseDistKind          -- ^ Case distinction kind
                -> SystemTraceQuantifier -- ^ Trace quantifier
                -> LNFormula
                -> System
formulaToSystem axioms kind traceQuantifier fm =
      insertLemmas safetyAxioms
    $ L.set sFormulas (S.singleton gf2)
    $ (emptySystem kind)
  where
    (safetyAxioms, otherAxioms) = partition isSafetyFormula axioms
    gf0 = formulaToGuarded_ fm
    gf1 = case traceQuantifier of
      ExistsSomeTrace -> gf0
      ExistsNoTrace   -> gnot gf0
    -- Non-safety axioms must be added to the formula, as they render the set
    -- of traces non-prefix-closed, which makes the use of induction unsound.
    gf2 = gconj $ gf1 : otherAxioms

-- | Add a lemma / additional assumption to a constraint system.
insertLemma :: LNGuarded -> System -> System
insertLemma =
    go
  where
    go (GConj conj) = foldr (.) id $ map go $ getConj conj
    go fm           = L.modify sLemmas (S.insert fm)

-- | Add lemmas / additional assumptions to a constraint system.
insertLemmas :: [LNGuarded] -> System -> System
insertLemmas fms sys = foldl' (flip insertLemma) sys fms

------------------------------------------------------------------------------
-- Queries
------------------------------------------------------------------------------


-- Nodes
------------

-- | A list of all KD-conclusions in the 'System'.
allKDConcs :: System -> [(NodeId, RuleACInst, LNTerm)]
allKDConcs sys = do
    (i, ru)                            <- M.toList $ L.get sNodes sys
    (_, kFactView -> Just (DnK, m)) <- enumConcs ru
    return (i, ru, m)

-- | @nodeRule v@ accesses the rule label of node @v@ under the assumption that
-- it is present in the sequent.
nodeRule :: NodeId -> System -> RuleACInst
nodeRule v se =
    fromMaybe errMsg $ M.lookup v $ L.get sNodes se
  where
    errMsg = error $
        "nodeRule: node '" ++ show v ++ "' does not exist in sequent\n" ++
        render (nest 2 $ prettySystem se)


-- | @nodePremFact prem se@ computes the fact associated to premise @prem@ in
-- sequent @se@ under the assumption that premise @prem@ is a a premise in
-- @se@.
nodePremFact :: NodePrem -> System -> LNFact
nodePremFact (v, i) se = L.get (rPrem i) $ nodeRule v se

-- | @nodePremNode prem@ is the node that this premise is referring to.
nodePremNode :: NodePrem -> NodeId
nodePremNode = fst

-- | All facts associated to this node premise.
resolveNodePremFact :: NodePrem -> System -> Maybe LNFact
resolveNodePremFact (v, i) se = lookupPrem i =<< M.lookup v (L.get sNodes se)

-- | The fact associated with this node conclusion, if there is one.
resolveNodeConcFact :: NodeConc -> System -> Maybe LNFact
resolveNodeConcFact (v, i) se = lookupConc i =<< M.lookup v (L.get sNodes se)

-- | @nodeConcFact (NodeConc (v, i))@ accesses the @i@-th conclusion of the
-- rule associated with node @v@ under the assumption that @v@ is labeled with
-- a rule that has an @i@-th conclusion.
nodeConcFact :: NodeConc -> System -> LNFact
nodeConcFact (v, i) = L.get (rConc i) . nodeRule v

-- | 'nodeConcNode' @c@ compute the node-id of the node conclusion @c@.
nodeConcNode :: NodeConc -> NodeId
nodeConcNode = fst


-- Actions
----------

-- | All actions that hold in a sequent.
unsolvedActionAtoms :: System -> [(NodeId, LNFact)]
unsolvedActionAtoms sys =
      do (ActionG i fa, status) <- M.toList (L.get sGoals sys)
         guard (not $ L.get gsSolved status)
         return (i, fa)

-- | All actions that hold in a sequent.
allActions :: System -> [(NodeId, LNFact)]
allActions sys =
      unsolvedActionAtoms sys
  <|> do (i, ru) <- M.toList $ L.get sNodes sys
         (,) i <$> L.get rActs ru

-- | All actions that hold in a sequent.
allKUActions :: System -> [(NodeId, LNFact, LNTerm)]
allKUActions sys = do
    (i, fa@(kFactView -> Just (UpK, m))) <- allActions sys
    return (i, fa, m)

-- | The standard actions, i.e., non-KU-actions.
standardActionAtoms :: System -> [(NodeId, LNFact)]
standardActionAtoms = filter (not . isKUFact . snd) . unsolvedActionAtoms

-- | All KU-actions.
kuActionAtoms :: System -> [(NodeId, LNFact, LNTerm)]
kuActionAtoms sys = do
    (i, fa@(kFactView -> Just (UpK, m))) <- unsolvedActionAtoms sys
    return (i, fa, m)

-- Destruction chains
---------------------

-- | All unsolved destruction chains in the constraint system.
unsolvedChains :: System -> [(NodeConc, NodePrem)]
unsolvedChains sys = do
    (ChainG from to, status) <- M.toList $ L.get sGoals sys
    guard (not $ L.get gsSolved status)
    return (from, to)


-- The temporal order
---------------------

-- | @(from,to)@ is in @rawEdgeRel se@ iff we can prove that there is an
-- edge-path from @from@ to @to@ in @se@ without appealing to transitivity.
rawEdgeRel :: System -> [(NodeId, NodeId)]
rawEdgeRel sys = map (nodeConcNode *** nodePremNode) $
     [(from, to) | Edge from to <- S.toList $ L.get sEdges sys]
  ++ unsolvedChains sys

-- | @(from,to)@ is in @rawLessRel se@ iff we can prove that there is a path
-- (possibly using the 'Less' relation) from @from@ to @to@ in @se@ without
-- appealing to transitivity.
rawLessRel :: System -> [(NodeId,NodeId)]
rawLessRel se = S.toList (L.get sLessAtoms se) ++ rawEdgeRel se

-- | Returns a predicate that is 'True' iff the first argument happens before
-- the second argument in all models of the sequent.
alwaysBefore :: System -> (NodeId -> NodeId -> Bool)
alwaysBefore sys =
    check -- lessRel is cached for partial applications
  where
    lessRel   = rawLessRel sys
    check i j =
         -- speed-up check by first checking less-atoms
         ((i, j) `S.member` L.get sLessAtoms sys)
      || (j `S.member` D.reachableSet [i] lessRel)

-- | 'True' iff the given node id is guaranteed to be instantiated to an
-- index in the trace.
isInTrace :: System -> NodeId -> Bool
isInTrace sys i =
     i `M.member` L.get sNodes sys
  || isLast sys i
  || any ((i ==) . fst) (unsolvedActionAtoms sys)

-- | 'True' iff the given node id is guaranteed to be instantiated to the last
-- index of the trace.
isLast :: System -> NodeId -> Bool
isLast sys i = Just i == L.get sLastAtom sys



------------------------------------------------------------------------------
-- Pretty printing                                                          --
------------------------------------------------------------------------------

-- | Pretty print a sequent
prettySystem :: HighlightDocument d => System -> d
prettySystem se = vcat $
    map combine
      [ ("nodes",          vcat $ map prettyNode $ M.toList $ L.get sNodes se)
      , ("actions",        fsepList ppActionAtom $ unsolvedActionAtoms se)
      , ("edges",          fsepList prettyEdge   $ S.toList $ L.get sEdges se)
      , ("less",           fsepList prettyLess   $ S.toList $ L.get sLessAtoms se)
      , ("unsolved goals", prettyGoals False se)
      ]
    ++ [prettyNonGraphSystem se]
  where
    combine (header, d) = fsep [keyword_ header <> colon, nest 2 d]
    ppActionAtom (i, fa) = prettyNAtom (Action (varTerm i) fa)

-- | Pretty print the non-graph part of the sequent; i.e. equation store and
-- clauses.
prettyNonGraphSystem :: HighlightDocument d => System -> d
prettyNonGraphSystem se = vsep $ map combine
  [ ("last",            maybe (text "none") prettyNodeId $ L.get sLastAtom se)
  , ("formulas",        vsep $ map prettyGuarded $ S.toList $ L.get sFormulas se)
  , ("equations",       prettyEqStore $ L.get sEqStore se)
  , ("distinct vars",   numbered' $ map (fsepList prettyNodeId) $ S.toList $ L.get sDistinctions se)
  , ("lemmas",          vsep $ map prettyGuarded $ S.toList $ L.get sLemmas se)
  , ("allowed cases",   text $ show $ L.get sCaseDistKind se)
  , ("solved formulas", vsep $ map prettyGuarded $ S.toList $ L.get sSolvedFormulas se)
  , ("solved goals",    prettyGoals True se)
  ]
  where
    combine (header, d) =
        caseEmptyDoc emptyDoc (fsep [keyword_ header <> colon, nest 2 d]) d

-- | Pretty print solved or unsolved goals.
prettyGoals :: HighlightDocument d => Bool -> System -> d
prettyGoals solved sys = vsep $ do
    (goal, status) <- M.toList $ L.get sGoals sys
    guard (solved == L.get gsSolved status)
    let nr  = L.get gsNr status
        loopBreaker | L.get gsLoopBreaker status = " (loop breaker)"
                    | otherwise                  = ""
    return $ prettyGoal goal <-> lineComment_ ("nr: " ++ show nr ++ loopBreaker)


-- Additional instances
-----------------------

deriving instance Show System

instance Apply CaseDistKind where
    apply = const id

instance HasFrees CaseDistKind where
    foldFrees = const mempty
    mapFrees  = const pure

instance HasFrees GoalStatus where
    foldFrees = const mempty
    mapFrees  = const pure

instance HasFrees System where
    foldFrees fun (System a b c d e f g h i j k l) =
        foldFrees fun a `mappend`
        foldFrees fun b `mappend`
        foldFrees fun c `mappend`
        foldFrees fun d `mappend`
        foldFrees fun e `mappend`
        foldFrees fun f `mappend`
        foldFrees fun g `mappend`
        foldFrees fun h `mappend`
        foldFrees fun i `mappend`
        foldFrees fun j `mappend`
        foldFrees fun k `mappend`
        foldFrees fun l

    mapFrees fun (System a b c d e f g h i j k l) =
        System <$> mapFrees fun a
               <*> mapFrees fun b
               <*> mapFrees fun c
               <*> mapFrees fun d
               <*> mapFrees fun e
               <*> mapFrees fun f
               <*> mapFrees fun g
               <*> mapFrees fun h
               <*> mapFrees fun i
               <*> mapFrees fun j
               <*> mapFrees fun k
               <*> mapFrees fun l


$( derive makeBinary ''CaseDistKind)
$( derive makeBinary ''GoalStatus)
$( derive makeBinary ''System)
$( derive makeBinary ''SystemTraceQuantifier)

$( derive makeNFData ''CaseDistKind)
$( derive makeNFData ''GoalStatus)
$( derive makeNFData ''System)
$( derive makeNFData ''SystemTraceQuantifier)
