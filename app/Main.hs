{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
module Main where

import           Control.Exception          (catchJust)
import           Codegen.C.CToR1cs          (fnToR1cs, fnToR1csWithWit)
import           Codegen.C                  (checkFn)
import qualified Codegen.Circom.Compilation as Comp
import qualified Codegen.Circom.CompTypes.WitComp
                                            as Wit
import qualified Codegen.Circom.CompTypes   as CompT
import qualified Codegen.Circom.Linking     as Link
import qualified IR.R1cs                    as R1cs
import qualified IR.R1cs.Opt                as Opt
import           Data.Field.Galois          (fromP)
import qualified Data.Map                   as Map
import qualified Data.IntMap                as IntMap
import qualified Data.Maybe                 as Maybe
import           Data.Proxy                 (Proxy(..))
import           Parser.C                   (parseC)
import           Parser.Circom              (loadMain)
import           System.Environment         (getArgs)
import           System.IO                  (hPutStr, IOMode(..), hClose, Handle, IOMode)
import           System.IO.Error            (isDoesNotExistError)
import qualified System.IO                  (openFile)
import           System.Console.Docopt
import           System.Process

openFile :: FilePath -> IOMode -> IO Handle
openFile path mode =
  catchJust (\e -> if isDoesNotExistError e then Just e else Nothing) (System.IO.openFile path mode) $ \e -> do
    putStrLn $ "Could not find file: " ++ path
    return $ error $ "Error: " ++ show e


patterns :: Docopt
patterns = [docopt|
Usage:
  compiler [options] emit-r1cs [options]
  compiler [options] count-terms [options]
  compiler [options] setup [options]
  compiler [options] prove [options]
  compiler [options] verify [options]
  compiler (-h | --help)
  compiler [options] c-check <fn-name> <path>
  compiler [options] c-emit-r1cs <fn-name> <path>
  compiler [options] c-setup <fn-name> <path>
  compiler [options] c-prove <fn-name> <path>

Options:
  -h, --help         Display this message
  --circom <path>    Read the circom circuit from this path [default: main.circom]
  -C <path>          Write the R1CS circuit to this path [default: C]
  -V <path>          Write the verifier key to this path [default: vk]
  -P <path>          Write the prover key to this path [default: pk]
  -i <path>          Read all inputs from this path [default: i]
  -x <path>          Write the public input to this path [default: x]
  -w <path>          Write the the auxiliary input to this path [default: w]
  -p <path>          Write/Read the proof at this path [default: pf]
  --libsnark <path>  Location of the libsnark binary [default: libsnark-frontend/build/src/main]
  -O --opt           Optimize the circuit

Commands:
  prove            Run the prover
  verify           Run the verifier
  setup            Run the setup
  emit-r1cs        Emit R1CS
  count-terms      Compile at the fn-level only
  c-check          Check a C function using an SMT solver
  c-emit-r1cs      Convert a C function to R1CS
  c-setup          Run setup for a C function
  c-prove          Write proof for a C function
|]

getArgOrExit :: Arguments -> Option -> IO String
getArgOrExit = getArgOrExitWith patterns


emitAssignment :: [Integer] -> FilePath -> IO ()
emitAssignment xs path = do
    handle <- openFile path WriteMode
    hPutStr handle $ concatMap (\i -> show i ++ "\n") (fromIntegral (length xs) : xs)
    hClose handle

-- libsnark functions
runSetup :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
runSetup libsnarkPath circuitPath pkPath vkPath = do
    print "Running libsnark"
    _ <- readProcess libsnarkPath ["setup", "-V", vkPath, "-P", pkPath, "-C", circuitPath] ""
    return ()

runProve :: FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
runProve libsnarkPath pkPath vkPath xPath wPath pfPath = do
    callProcess libsnarkPath ["prove", "-V", vkPath, "-P", pkPath, "-x", xPath, "-w", wPath, "-p", pfPath]
    return ()

runVerify :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
runVerify libsnarkPath vkPath xPath pfPath  = do
    _ <- readProcess libsnarkPath ["verify", "-V", vkPath, "-x", xPath, "-p", pfPath] ""
    return ()

order :: Integer
order = 21888242871839275222246405745257275088548364400416034343698204186575808495617
type Order = 21888242871839275222246405745257275088548364400416034343698204186575808495617

-- order = 17
-- type Order = 17
-- type OrderCtx = Ctx Order

cmdEmitR1cs :: Bool -> FilePath -> FilePath -> IO ()
cmdEmitR1cs opt circomPath r1csPath = do
    print "Loading circuit"
    m <- loadMain circomPath
    let optFn = if opt then Opt.opt else id
    let r1cs = optFn $ Link.linkMain @Order m
    putStrLn $ R1cs.r1csStats r1cs
    putStrLn $ R1cs.r1csShow r1cs
    R1cs.writeToR1csFile r1cs r1csPath

cmdCountTerms :: FilePath -> IO ()
cmdCountTerms circomPath = do
    m <- loadMain circomPath
    let c = Comp.compMainWitCtx @Order m
    print $ count c + sum (Map.map count $ CompT.cache c)
    print c
    where
     count = Wit.nSmtNodes . CompT.baseCtx


cmdSetup :: Bool -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
cmdSetup opt libsnarkPath circomPath r1csPath pkPath vkPath = do
    cmdEmitR1cs opt circomPath r1csPath
    runSetup libsnarkPath r1csPath pkPath vkPath

cmdProve :: Bool -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
cmdProve opt libsnarkPath pkPath vkPath inPath xPath wPath pfPath circomPath = do
    m <- loadMain circomPath
    inputFile <- openFile inPath ReadMode
    inputsSignals <- Link.parseSignalsFromFile (Proxy @Order) inputFile
    let allSignals = Link.computeWitnesses (Proxy @Order) m inputsSignals
    let optFn = if opt then Opt.opt else id
    let r1cs = optFn $ Link.linkMain @Order m
    let getOr m_ k = Maybe.fromMaybe (error $ "Missing sig: " ++ show k) $ m_ Map.!? k
    let getOrI m_ k = Maybe.fromMaybe (error $ "Missing sig num: " ++ show k) $ m_ IntMap.!? k
    let lookupSignalVal :: Int -> Integer = getOr allSignals . getOrI (Link.numSigs r1cs)
    emitAssignment (map lookupSignalVal [2..(1 + Link.nPublicInputs r1cs)]) xPath
    emitAssignment (map lookupSignalVal [(2 + Link.nPublicInputs r1cs)..(Link.nextSigNum r1cs - 1)]) wPath
    runProve libsnarkPath pkPath vkPath xPath wPath pfPath

cmdVerify :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
cmdVerify = runVerify

cmdCCheck :: String -> FilePath -> IO ()
cmdCCheck name path = do
    tu <- parseC path
    r <- checkFn tu name
    case r of
      Just s -> putStrLn s
      Nothing -> putStrLn "No bug"

cmdCEmitR1cs :: Bool -> String -> FilePath -> FilePath -> IO ()
cmdCEmitR1cs opt fnName cPath r1csPath = do
    tu <- parseC cPath
    r1cs <- fnToR1cs @Order opt tu fnName
    R1cs.writeToR1csFile r1cs r1csPath

cmdCSetup :: Bool -> FilePath -> String -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
cmdCSetup opt libsnarkPath fnName cPath r1csPath pkPath vkPath = do
    cmdCEmitR1cs opt fnName cPath r1csPath
    runSetup libsnarkPath r1csPath pkPath vkPath

cmdCProve :: Bool -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> String -> FilePath -> IO ()
cmdCProve opt libsnarkPath pkPath vkPath inPath xPath wPath pfPath fnName cPath = do
    tu <- parseC cPath
    inputFile <- openFile inPath ReadMode
    inputsSignals <- Link.parseIntsFromFile inputFile
    (r1cs, w) <- fnToR1csWithWit @Order inputsSignals opt tu fnName
    let getOr m_ k = Maybe.fromMaybe (error $ "Missing sig: " ++ show k) $ m_ Map.!? k
    let getOrI m_ k = Maybe.fromMaybe (error $ "Missing sig num: " ++ show k) $ m_ IntMap.!? k
    let lookupSignalVal :: Int -> Integer
        lookupSignalVal i = fromP $ getOr w $ getOrI (Link.numSigs r1cs) i
    emitAssignment (map lookupSignalVal [2..(1 + Link.nPublicInputs r1cs)]) xPath
    emitAssignment (map lookupSignalVal [(2 + Link.nPublicInputs r1cs)..(Link.nextSigNum r1cs - 1)]) wPath
    runProve libsnarkPath pkPath vkPath xPath wPath pfPath

defaultR1cs :: String
defaultR1cs = "C"

main :: IO ()
main = do
    args <- parseArgsOrExit patterns =<< getArgs
    let optimize = args `isPresent` longOption "opt"
    if args `isPresent` command "emit-r1cs" then do
        circomPath <- args `getArgOrExit` longOption "circom"
        r1csPath <- args `getArgOrExit` shortOption 'C'
        cmdEmitR1cs optimize circomPath r1csPath
    else if args `isPresent` command "count-terms" then do
        circomPath <- args `getArgOrExit` longOption "circom"
        cmdCountTerms circomPath
    else if args `isPresent` command "setup" then do
        libsnarkPath <- args `getArgOrExit` longOption "libsnark"
        circomPath <- args `getArgOrExit` longOption "circom"
        r1csPath <- args `getArgOrExit` shortOption 'C'
        pkPath <- args `getArgOrExit` shortOption 'P'
        vkPath <- args `getArgOrExit` shortOption 'V'
        cmdSetup optimize libsnarkPath circomPath r1csPath pkPath vkPath
    else if args `isPresent` command "prove" then do
        libsnarkPath <- args `getArgOrExit` longOption "libsnark"
        circomPath <- args `getArgOrExit` longOption "circom"
        pkPath <- args `getArgOrExit` shortOption 'P'
        vkPath <- args `getArgOrExit` shortOption 'V'
        inPath <- args `getArgOrExit` shortOption 'i'
        xPath <- args `getArgOrExit` shortOption 'x'
        wPath <- args `getArgOrExit` shortOption 'w'
        pfPath <- args `getArgOrExit` shortOption 'p'
        cmdProve optimize libsnarkPath pkPath vkPath inPath xPath wPath pfPath circomPath
    else if args `isPresent` command "verify" then do
        libsnarkPath <- args `getArgOrExit` longOption "libsnark"
        vkPath <- args `getArgOrExit` shortOption 'V'
        xPath <- args `getArgOrExit` shortOption 'x'
        pfPath <- args `getArgOrExit` shortOption 'p'
        cmdVerify libsnarkPath vkPath xPath pfPath
    else if args `isPresent` command "c-check" then do
        fnName <- args `getArgOrExit` argument "fn-name"
        path <- args `getArgOrExit` argument "path"
        cmdCCheck fnName path
    else if args `isPresent` command "c-emit-r1cs" then do
        fnName <- args `getArgOrExit` argument "fn-name"
        path <- args `getArgOrExit` argument "path"
        r1csPath <- args `getArgOrExit` shortOption 'C'
        cmdCEmitR1cs optimize fnName path r1csPath
    else if args `isPresent` command "c-setup" then do
        libsnarkPath <- args `getArgOrExit` longOption "libsnark"
        fnName <- args `getArgOrExit` argument "fn-name"
        cPath <- args `getArgOrExit` argument "path"
        r1csPath <- args `getArgOrExit` shortOption 'C'
        pkPath <- args `getArgOrExit` shortOption 'P'
        vkPath <- args `getArgOrExit` shortOption 'V'
        cmdCSetup optimize libsnarkPath fnName cPath r1csPath pkPath vkPath
    else if args `isPresent` command "c-prove" then do
        libsnarkPath <- args `getArgOrExit` longOption "libsnark"
        fnName <- args `getArgOrExit` argument "fn-name"
        cPath <- args `getArgOrExit` argument "path"
        pkPath <- args `getArgOrExit` shortOption 'P'
        vkPath <- args `getArgOrExit` shortOption 'V'
        inPath <- args `getArgOrExit` shortOption 'i'
        xPath <- args `getArgOrExit` shortOption 'x'
        wPath <- args `getArgOrExit` shortOption 'w'
        pfPath <- args `getArgOrExit` shortOption 'p'
        cmdCProve optimize libsnarkPath pkPath vkPath inPath xPath wPath pfPath fnName cPath
    else
        exitWithUsageMessage patterns "Missing command!"
