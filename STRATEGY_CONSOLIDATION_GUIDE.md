# Strategy Consolidation Guide

## Document Purpose
This guide documents the lessons learned and design decisions from consolidating multiple strategy branches into a unified implementation. Use this when restarting from a fresh branch.

## Goal
Merge 6 strategy branches (backTrackUptodate, blackListUptodate, escapeTacticGenUptodate, escapeUptodate, probaUptodate, smartTamarinUptodate) into one branch (feature-strategies) with a command-line switch to select strategies.

**Critical Requirement**: All terminating strategies and heuristics must return the same result (verified or falsified) for the same input - different results indicate a soundness bug.

## Key Conceptual Distinction: Strategies vs Heuristics

### Heuristics
- **Scope**: Work within a single proof attempt
- **Purpose**: Rank/prioritize goals in the current proof search
- **Implementation**: Affect goal ordering, not search space
- **Command-line**: `--heuristic=` flag (e.g., `s`, `S`, `c`, `C`, `i`, `I`)
- **Examples**: SmartRanking, GoalNrRanking, InjRanking, SapicRanking

### Strategies
- **Scope**: Work across multiple proof attempts
- **Purpose**: Control backtracking and multi-attempt reasoning
- **Implementation**: Can mark proof states for revisiting, track exploration history
- **Command-line**: `--strategy=` flag (separate from heuristics)
- **Examples**: BackTrack, BlackList, Escape, SmartTamarin, Proba

**CRITICAL**: Strategies and heuristics are fundamentally different concepts and must not be mixed in the type system.

## Architecture Design

### 1. Strategy Type (Theory/Constraint/System.hs)
```haskell
-- | Strategies control the overall proof search approach, including backtracking
-- and reasoning about multiple proof attempts. They work at a higher level than
-- heuristics, which only affect goal ranking within a single proof attempt.
data Strategy = 
    DefaultStrategy              -- ^ No special strategy (standard DFS)
  | BackTrackStrategy            -- ^ Loop detection with backtracking
  | BlackListStrategy            -- ^ Goal blacklisting strategy
  | EscapeStrategy               -- ^ Escape strategy
  | EscapeTacticGenStrategy      -- ^ Escape with tactic generation
  | SmartTamarinStrategy         -- ^ Advanced loop detection
  | ProbaStrategy                -- ^ Probabilistic strategy
  deriving (Eq, Ord, Show, Generic, NFData, Binary)

defaultStrategy :: Strategy
defaultStrategy = DefaultStrategy

strategyIdentifiers :: M.Map String Strategy
strategyIdentifiers = M.fromList
    [ ("default", DefaultStrategy)
    , ("backtrack", BackTrackStrategy)
    , ("blacklist", BlackListStrategy)
    , ("escape", EscapeStrategy)
    , ("escapetactic", EscapeTacticGenStrategy)
    , ("smarttamarin", SmartTamarinStrategy)
    , ("proba", ProbaStrategy)
    ]
```

### 2. StrategyInfo Type (Theory/Constraint/Solver/StrategyInfo.hs)
Generic container for strategy-specific state:

```haskell
data StrategyInfo = 
    NoStrategyInfo
  | BackTrackStrategyInfo BackTrackInfo
  | SmartTamarinStrategyInfo SmartTamarinInfo
  | EscapeStrategyInfo EscapeInfo
  | BlackListStrategyInfo BlackListInfo
  | ProbaStrategyInfo ProbaInfo
  deriving (Show, Generic, NFData, Binary)

-- Strategy-specific info structures
data BackTrackInfo = BackTrackInfo {
    btiPathGoals :: [[Goal]],
    btiNbLoop :: Int,
    btiLoopFound :: Bool
}

data SmartTamarinInfo = SmartTamarinInfo {
    stiLoopList :: [(Int, Int, [Goal])],
    stiCurrentLoop :: (Int, Int),
    stiLoopFound :: Bool
}

-- Similar for EscapeInfo, BlackListInfo, ProbaInfo
```

### 3. System Extension
Add strategy info field to System (14 fields total):
```haskell
data System = System
    { _sAtoms           :: ...
    , _sGoals           :: ...
    , ...
    , _sStrategyInfo    :: StrategyInfo  -- NEW: Strategy-specific state
    }
```

### 4. ProofContext Extension
Add strategy selection field:
```haskell
data ProofContext = ProofContext
    { _pcSignature          :: SignatureWithMaude
    , _pcRules              :: ClassifiedRules
    , ...
    , _pcStrategy           :: Strategy  -- NEW: Active strategy
    , _pcTraceQuantifier    :: SystemTraceQuantifier
    , ...
    }
```

### 5. ProofMethod Extensions (Theory/Constraint/Solver/ProofMethod.hs)
Add strategy-specific proof method markers:

```haskell
data ProofMethod =
    ...
  | Backtracked Goal                -- Marks backtracked goals
  | InLoop LoopInfo                 -- Marks methods creating loops
  | Incorrect IncorrectnessInfo     -- Marks incorrect proof attempts

data LoopInfo = 
    BackTrackLoop Int (Maybe Goal)
  | SmartTamarinLoop Int Int Goal
  | EscapeLoop Int Int Goal
  | ProbaLoop Int Int Goal Int

data IncorrectnessInfo = IncorrectnessInfo {
    iiScore :: Int,
    iiDepth :: Int,
    iiGoal :: Maybe Goal,
    iiSkipList :: [Maybe Goal]
}
```

## Implementation Lessons

### CRITICAL: Soundness Requirement
**Strategies must work ONLY through ranking, never by pruning search paths.**

#### What Went Wrong
Initial implementation modified `proveSystemDFS` to skip certain proof states:
```haskell
-- WRONG - causes soundness bugs
proveSystemDFS ignoreGoals explore ctxt sys = case explore ctxt sys of
    Nothing -> solveGoal ctxt sys
    Just [] -> return M.empty  -- PRUNING - loses soundness
```

This caused BackTrack strategy to verify a lemma while Smart heuristic falsified it - a soundness violation.

#### Correct Approach
Keep `proveSystemDFS` simple and unchanged. Strategies affect ranking only:

```haskell
-- Strategies work through ranking transformation
applyStrategyRanking :: Strategy -> [(ProofMethod, ...)] -> [(ProofMethod, ...)]
applyStrategyRanking BackTrackStrategy methods = rankWithLoop $ map wrapLoopMethods methods
applyStrategyRanking _ methods = methods

-- Move loop methods to end of list (defers them, doesn't skip them)
rankWithLoop :: [(ProofMethod, ...)] -> [(ProofMethod, ...)]
rankWithLoop [] = []
rankWithLoop ((InLoop _, cases):l) = rankWithLoop l ++ [(InLoop ..., cases)]
rankWithLoop (h:t) = h : rankWithLoop t
```

**Key Insight**: Deferring proof methods to the end of the list = exploring them last. This preserves completeness while achieving the strategy's goal.

### BackTrack Strategy Implementation

#### Goal Normalization
```haskell
-- Remove variable indices to detect structural loops
freeme :: Goal -> Goal
freeme (ActionG i (Fact tag kind terms)) = 
    ActionG i (Fact tag kind (map freeVariables terms))
freeme (PremiseG p (Fact tag kind terms)) = 
    PremiseG p (Fact tag kind (map freeVariables terms))
-- ... similar for other goal types

freeVariables :: LNTerm -> LNTerm
freeVariables (varTerm (LVar name _ idx)) = varTerm (LVar name LSortMsg 0)
-- Removes variable indices to match structurally similar goals
```

#### Loop Detection
In `rankProofMethods`, check if solving a goal recreates a previous state:

```haskell
checkForLoops :: ProofMethod -> M.Map CaseName System -> M.Map CaseName System
checkForLoops method cases = case L.get pcStrategy ctxt of
    BackTrackStrategy -> M.map (checkSystemForLoop method) cases
    _ -> cases

checkSystemForLoop :: ProofMethod -> System -> System
checkSystemForLoop method sys' = case method of
    SolveGoal goal -> 
        let bti = getBackTrackInfo sys'
            pathGoals = btiPathGoals bti
            normalizedGoal = freeme goal
            foundAt = findGoalInPath normalizedGoal pathGoals 0
        in if foundAt >= 0
           then markLoopFound sys' foundAt
           else extendPath sys' normalizedGoal
    _ -> sys'
```

#### Loop Handling
Wrap loop-creating methods in `InLoop` constructor, then defer them:

```haskell
wrapLoopMethods :: (ProofMethod, ...) -> (ProofMethod, ...)
wrapLoopMethods (method, (cases, expl)) =
    case M.toList cases of
        ((_, sys'):_) -> 
            case L.get sStrategyInfo sys' of
                BackTrackStrategyInfo bti | btiLoopFound bti ->
                    let loopInfo = BackTrackLoop (btiNbLoop bti) (extractGoalFromMethod method)
                    in (InLoop loopInfo, (cases, "InLoop " ++ show (btiNbLoop bti)))
                _ -> (method, (cases, expl))

-- Then rankWithLoop moves InLoop methods to end
```

### Type System Organization

**DO NOT** add strategies to `GoalRanking` enum. This was a fundamental mistake that mixed two different concepts.

**CORRECT** structure:
- `Strategy` enum: Separate type for strategy selection
- `GoalRanking` enum: Only contains heuristics (SmartRanking, InjRanking, etc.)
- `ProofContext._pcStrategy`: Strategy field
- `ProofContext._pcHeuristic`: Heuristic field (separate)

### Command-Line Integration

**DO NOT** add strategy flags to `goalRankingIdentifiers` (those are for `--heuristic=`).

**CORRECT** approach:
1. Create `strategyIdentifiers` map
2. Add `--strategy=` command-line option (separate from `--heuristic=`)
3. Parse strategy name and set `ProofContext._pcStrategy`
4. Default to `DefaultStrategy` when not specified

## Remaining Work

### 1. Fix Lens Generation Issue
Current error: `pcStrategy` lens not in scope. Need to either:
- Add `pcStrategy` to explicit export list
- Use `_pcStrategy` directly in code
- Ensure mkLabels properly generates and exports the lens

### 2. Update All ProofContext Creation Sites
Find all places that create ProofContext and add `_pcStrategy = defaultStrategy`:
```bash
grep -r "ProofContext" --include="*.hs" | grep -v "^--" | grep "{" 
```

### 3. Command-Line Parsing
Add `--strategy=` option parsing in Main/Console.hs or similar:
- Accept strategy names: "default", "backtrack", "blacklist", "escape", etc.
- Set `ProofContext._pcStrategy` accordingly
- Add help text explaining strategy vs heuristic distinction

### 4. Implement Other Strategies
Currently only BackTrack is implemented. For each strategy:
- Define strategy-specific info structure in StrategyInfo.hs
- Implement loop/state detection logic
- Implement ranking transformation in `applyStrategyRanking`
- Ensure soundness: work through ranking only, not path pruning

### 5. Testing
For each strategy:
- Test that it finds the same result as Smart heuristic on known theories
- Test on examples from original branches (backTrackUptodate/*, etc.)
- Verify soundness: no verified/falsified discrepancies

### 6. Documentation
- Update user manual with `--strategy=` option
- Document strategy vs heuristic distinction
- Provide examples of when each strategy is useful

## Testing Command
```bash
# Test BackTrack strategy (once command-line parsing is added)
stack exec tamarin-prover -- --strategy=backtrack --prove=test_lemma test-backtrack.spthy

# Compare with smart heuristic
stack exec tamarin-prover -- --heuristic=s --prove=test_lemma test-backtrack.spthy

# Results must match (both verified or both falsified)
```

## Files Modified (Current Attempt)
- `lib/theory/src/Theory/Constraint/Solver/StrategyInfo.hs` - Complete
- `lib/theory/src/Theory/Constraint/System.hs` - Partially complete (lens issue)
- `lib/theory/src/Theory/Constraint/Solver/ProofMethod.hs` - Complete for BackTrack
- `lib/theory/src/Theory/Proof.hs` - Kept unchanged (correct approach)

## Common Pitfalls to Avoid

1. **DON'T** modify `proveSystemDFS` to skip proof states - breaks soundness
2. **DON'T** mix Strategy and GoalRanking types - conceptually different
3. **DON'T** prune search paths - only reorder them
4. **DON'T** use `--heuristic=` for strategies - use `--strategy=`
5. **DO** work entirely through ranking transformations
6. **DO** test soundness by comparing with Smart heuristic
7. **DO** keep strategies separate from heuristics in type system
8. **DO** normalize goals (freeme) before loop detection

## Quick Start for Fresh Branch

1. Cherry-pick StrategyInfo.hs creation commit
2. Add Strategy type to System.hs (separate from GoalRanking)
3. Add _pcStrategy field to ProofContext
4. Export Strategy type and support functions
5. Update ProofMethod.hs to check pcStrategy instead of GoalRanking
6. Add command-line parsing for --strategy=
7. Update all ProofContext creation sites
8. Test with BackTrack on test-backtrack.spthy
9. Implement remaining strategies one by one
10. Run full regression test suite

## Reference Implementation: BackTrack

See test-backtrack.spthy for example theory that demonstrates loop detection:
```spthy
theory Test
begin

rule Init:
  [ Fr(~k) ]
  -->
  [ State(~k, '1') ]

rule Loop:
  [ State(k, s) ]
  -->
  [ State(k, s) ]  // Creates loop

lemma test:
  "All k s #i. State(k, s) @ i ==> F"
  // Should be falsified (trace exists)

end
```

Both BackTrack and Smart must find: "falsified - found trace (5 steps)"

## Success Criteria

✅ All strategies compile without errors
✅ BackTrack strategy detects and defers loops
✅ All strategies return same results as Smart heuristic
✅ Command-line `--strategy=` option works
✅ No soundness bugs (verified vs falsified mismatches)
✅ Regression tests pass
✅ Documentation updated

## Contact/Questions

See STRATEGY_PROGRESS_REPORT.md for detailed progress tracking of this consolidation effort.
