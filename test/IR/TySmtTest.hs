{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE AllowAmbiguousTypes           #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE ScopedTypeVariables #-}
module IR.TySmtTest where
import           BenchUtils
import           Control.Monad                  ( unless )
import qualified Data.BitVector                as Bv
import           Data.Dynamic
import qualified Data.Map.Strict               as Map
import qualified IR.TySmt                      as Smt
import           GHC.TypeLits

tySmtTests :: BenchTest
tySmtTests = benchTestGroup
  "Typed SMT Tests"
  [ genEvalTest "boolean literal, empty context"
                Map.empty
                (Smt.BoolLit True)
                (Smt.ValBool True)
  , genEvalTest "integer expression, with bound variable"
                (Map.fromList [("a", toDyn (Smt.ValInt 4))])
                (Smt.IntBinExpr Smt.IntSub (Smt.mkVar "a") (Smt.IntLit 1))
                (Smt.ValInt 3)
  , genEvalTest
    "field expression, with bound variables"
    (Map.fromList [("a", toDyn (Smt.ValPf @5 4)), ("b", toDyn (Smt.ValPf @5 3))]
    )
    (Smt.PfNaryExpr
      Smt.PfMul
      [Smt.mkVar "a", Smt.IntToPf @5 (Smt.IntLit 3), Smt.mkVar "b"]
    )
    (Smt.ValPf @5 1)
  , genEvalTest
    "bv expression"
    Map.empty
    (Smt.BvBinExpr Smt.BvAnd
                   (Smt.IntToBv @4 (Smt.IntLit 9))
                   (Smt.IntToBv @4 (Smt.IntLit 10))
    )
    (Smt.ValBv @4 (Bv.bitVec 4 (8 :: Int)))
  , genEvalTest
    "dyanmic width bv expression"
    Map.empty
    (Smt.mkStatifyBv @4
      (Smt.mkDynBvExtract 1 4 (Smt.mkDynamizeBv (Smt.IntToBv @6 (Smt.IntLit 0)))
      )
    )
    (Smt.ValBv @4 (Bv.bitVec 4 (0 :: Int)))
  , genEvalTest
    "field -> int -> bv -> shift -> int -> field"
    (Map.fromList [("a", toDyn (Smt.ValPf @17 4))])
    (Smt.IntToPf @17
      (Smt.BvToInt
        (Smt.BvBinExpr Smt.BvLshr
                       (Smt.IntToBv @5 (Smt.PfToInt @17 (Smt.mkVar "a")))
                       (Smt.IntToBv @5 (Smt.IntLit 1))
        )
      )
    )
    (Smt.ValPf @17 2)
  , genOverflowTest @4 Smt.BvSaddo False "high" 3 4
  , genOverflowTest @4 Smt.BvSaddo True "high" 4 4
  , genOverflowTest @4 Smt.BvSaddo False "low" (-3) (-5)
  , genOverflowTest @4 Smt.BvSaddo True "low" (-3) (-6)
  , genOverflowTest @4 Smt.BvSmulo False "high" 1 7
  , genOverflowTest @4 Smt.BvSmulo True "high" 2 4
  , genOverflowTest @4 Smt.BvSmulo False "low" (-2) 4
  , genOverflowTest @4 Smt.BvSmulo True "low" (-3) 3
  , genOverflowTest @4 Smt.BvSsubo False "high" 0 (-7)
  , genOverflowTest @4 Smt.BvSsubo True "high" 0 (-8)
  , genOverflowTest @4 Smt.BvSsubo False "low" (-3) 5
  , genOverflowTest @4 Smt.BvSsubo True "low" (-3) 6
  ]

genOverflowTest
  :: forall n
   . KnownNat n
  => Smt.BvBinPred
  -> Bool
  -> String
  -> Integer
  -> Integer
  -> BenchTest
genOverflowTest p res name a b = genEvalTest
  (unwords [show p, if res then "  " else "no", "overflow:", name])
  (Map.fromList [])
  (Smt.BvBinPred p
                 (Smt.IntToBv @n (Smt.IntLit a))
                 (Smt.IntToBv @n (Smt.IntLit b))
  )
  (Smt.ValBool res)

type Env = Map.Map String Dynamic

genEvalTest
  :: (Typeable s) => String -> Env -> Smt.Term s -> Smt.Value s -> BenchTest
genEvalTest name ctx t v' = benchTestCase ("eval test: " ++ name) $ do
  let v = Smt.eval ctx t
  unless (v == v')
    $  error
    $  "Expected\n\t"
    ++ show t
    ++ "\nto evaluate to\n\t"
    ++ show v'
    ++ "\nbut it evaluated to\n\t"
    ++ show v
    ++ "\n"
  return ()