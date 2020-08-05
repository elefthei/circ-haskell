{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE TypeApplications    #-}
module IR.SMT.ToPfTest
  ( toPfTests
  )
where
import           Control.Monad
import           BenchUtils
import           Test.Tasty.HUnit
import           IR.SMT.ToPf                    ( toPf )
import           IR.R1cs                        ( R1CS(..)
                                                , r1csShow
                                                )
import qualified Data.Set                      as Set
import           IR.SMT.TySmt

type Order
  = 113890009193798365449144652900867294558768981710660728242748762258461992583217

constraintCountTest :: String -> [TermBool] -> Int -> BenchTest
constraintCountTest name terms nConstraints =
  benchTestCase (nameWithConstraints name nConstraints) $ do
    cs <- toPf @Order Nothing Set.empty terms
    when (nConstraints /= length (constraints cs)) $ putStrLn "" >> putStrLn
      (r1csShow cs)
    nConstraints @=? length (constraints cs)

nameWithConstraints :: String -> Int -> String
nameWithConstraints name i = unwords [name, "in", show i, "constraints"]

bv :: String -> TermBool
bv name = Var name SortBool

int :: String -> Int -> TermDynBv
int name width = Var name $ SortBv width

bvs :: Int -> [TermBool]
bvs i = map bv $ take i $ map (flip (:) []) ['a' ..]

andOrScalingTest :: BoolNaryOp -> Int -> BenchTest
andOrScalingTest op arity =
  let nOpConstraints = if arity < 2
        then 0
        -- arity - 1 is the cost of doing this with multiplication-ANDs
        -- 3 is the cost of doing this with addition/inverse-ORs
        else min (arity - 1) 3
      nC = nOpConstraints + arity + 1
  in  constraintCountTest (show op ++ show arity)
                          [BoolNaryExpr op (bvs arity)]
                          nC


toPfTests :: BenchTest
toPfTests = benchTestGroup
  "toPf"
  [ benchTestGroup
    "boolToPf"
    [ constraintCountTest "true lit"    [BoolLit True]             1
    -- One bit constraint, one const constraint
    , constraintCountTest "var is true" [bv "a"]                   2
    -- Three bit constraints, one const constraint, two for XOR
    , constraintCountTest "xor2"        [BoolNaryExpr Xor (bvs 2)] 6
    -- Two bit constraints, one const constraint, one for IMPLIES (an AND) v
    -- return b
    , constraintCountTest "implies" [BoolBinExpr Implies (bv "a") (bv "b")] 4
    -- Two bit constraints, one const constraint, one for AND
    , benchTestGroup "and" (map (andOrScalingTest And) [0 .. 6])
    , benchTestGroup "or"  (map (andOrScalingTest And) [0 .. 6])
    -- Three bit constraints, one const constraint, two for AND
    , constraintCountTest "and4 3 repeats"
                          [BoolNaryExpr And [bv "a", bv "b", bv "a", bv "a"]]
                          6
    , constraintCountTest "ite" [Ite (bv "a") (bv "b") (bv "c")] 6
    -- Thre bit constraints, one const constraint, two for Eq
    , constraintCountTest "eq"  [Eq (bv "a") (bv "b")]           5
    ]
  , benchTestGroup
    "bvToPf"
    [ constraintCountTest "5"
                          [mkDynBvEq (int "a" 4) (IntToDynBv 4 $ IntLit 5)]
                          9
    , constraintCountTest
      "5 = x + y"
      [ mkDynBvEq (mkDynBvBinExpr BvAdd (int "x" 4) (int "y" 4))
                  (IntToDynBv 4 $ IntLit 5)
      ]
      20
    , constraintCountTest "x < y"
                          [mkDynBvBinPred BvUlt (int "x" 4) (int "y" 4)]
                          -- Two 5bvs + 4 bits in the comparison difference + 3
                          -- bits in the comparison logic + 1 assertion bit
                          (2 * 5 + 4 + 3 + 1)
    , constraintCountTest
      "17 = x << y"
      [ mkDynBvEq (mkDynBvBinExpr BvShl (int "x" 16) (int "y" 16))
                  (IntToDynBv 16 $ IntLit 17)
      ]
      (let inputBounds = 17 * 2
           shiftRBound = 1
           shiftMults  = 4
           sumSplit    = 16 * 2
           eq          = 3
           forceBool   = 1
       in  inputBounds + shiftRBound + shiftMults + sumSplit + eq + forceBool
      )
    , constraintCountTest
      "17 = x >> y (logical)"
      [ mkDynBvEq (mkDynBvBinExpr BvLshr (int "x" 16) (int "y" 16))
                  (IntToDynBv 16 $ IntLit 17)
      ]
      (let inputBounds = 17 * 2
           shiftRBound = 1
           shiftMults  = 4
           sumSplit    = 16 * 2
           eq          = 3
           forceBool   = 1
       in  inputBounds + shiftRBound + shiftMults + sumSplit + eq + forceBool
      )
    , constraintCountTest
      "17 = x >> y (arithmetic)"
      [ mkDynBvEq (mkDynBvBinExpr BvAshr (int "x" 16) (int "y" 16))
                  (IntToDynBv 16 $ IntLit 17)
      ]
      (let inputBounds = 17 * 2
           shiftRBound = 1
           shiftMults  = 4
           shiftExtMults  = 4
           sumSplit    = 16 * 2
           eq          = 3
           forceBool   = 1
       in  inputBounds + shiftRBound + shiftMults + shiftExtMults + sumSplit + eq + forceBool
      )
    ]
  ]
