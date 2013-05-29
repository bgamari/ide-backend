{-# LANGUAGE CPP, DeriveDataTypeable, FlexibleInstances,
             GeneralizedNewtypeDeriving, MultiParamTypeClasses, TemplateHaskell,
             TypeSynonymInstances, ScopedTypeVariables #-}
-- | A few specialized walks over the Haskell AST. Heavily depends
-- on the GHC patches.
--
-- Only @IdeSession.GHC.Run@ and @IdeSession.GHC.HsWalk@ should import
-- any modules from the ghc package and the modules should not be reexported
-- anywhere else, with the exception of @IdeSession.GHC.Server@.
module HsWalk
  ( extractIdsPlugin
  , extractSourceSpan
  , idInfoForName
  , constructExplicitSharingCache
  , moduleNameToId
  , fillVersion
  , mainPackage
  ) where

import Control.Arrow (first, second)
import Control.Monad (forM_)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Control.Monad.State.Class (MonadState(..))
import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Exception (evaluate)
import Control.Applicative ((<$>))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSSC
import Data.List (stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Version
import Prelude hiding (id, mod, span)
import System.IO.Unsafe (unsafePerformIO)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

import IdeSession.Types.Private
import IdeSession.Strict.Container
import qualified IdeSession.Strict.IntMap as IntMap
import qualified IdeSession.Strict.Map    as Map
import qualified IdeSession.Strict.Maybe  as Maybe
import IdeSession.Strict.IORef
import IdeSession.Strict.StateT

import Bag
import DataCon (dataConName)
import FastString (FastString, unpackFS)
import GHC hiding (PackageId, idType, moduleName, ModuleName)
import qualified GHC
import HscPlugin
import qualified Module
import MonadUtils (MonadIO (..))
import qualified Name
import OccName
import Outputable hiding (getPprStyle)
import qualified Packages
import qualified RdrName
import TcRnTypes
import TcType (tidyOpenType)
import Var hiding (idInfo)
import VarEnv (TidyEnv, emptyTidyEnv)
import Unique (Unique, Uniquable, getUnique, getKey)
import HscTypes (TypeEnv, HscEnv(hsc_dflags), mkPrintUnqualified)
import NameEnv (nameEnvUniqueElts)
import DataCon (dataConRepType)
import Pretty (showDocWith, Mode(OneLineMode))
import PprTyThing (pprTypeForUser)

#define DEBUG 1

{------------------------------------------------------------------------------
  Caching

  We use explicit sharing so that we can maintain sharing through the JSON
  serialization.
------------------------------------------------------------------------------}

idPropCacheRef :: StrictIORef (Strict IntMap IdProp)
{-# NOINLINE idPropCacheRef #-}
idPropCacheRef = unsafePerformIO $ newIORef IntMap.empty

filePathCacheRef :: StrictIORef (HashMap FilePath Int, Int)
{-# NOINLINE filePathCacheRef #-}
filePathCacheRef = unsafePerformIO $ newIORef (HashMap.empty, 0)

modifyIdPropCache :: MonadIO m => IdPropPtr -> (IdProp -> IdProp) -> m ()
modifyIdPropCache ptr f = liftIO $ do
  cache <- readIORef idPropCacheRef
  let uniq = idPropPtr ptr
  writeIORef idPropCacheRef $ IntMap.adjust f uniq cache

extendIdPropCache :: MonadIO m => IdPropPtr -> IdProp -> m ()
extendIdPropCache ptr prop = liftIO $ do
  cache <- readIORef idPropCacheRef
  -- Don't overwrite existing entries, because we might lose type information
  -- that we gleaned earlier
  let uniq = idPropPtr ptr
  writeIORef idPropCacheRef $ IntMap.insertWith (\_new old -> old) uniq prop cache

mkFilePathPtr :: FilePath -> IO FilePathPtr
mkFilePathPtr path = do
  (hash, next) <- readIORef filePathCacheRef
  case HashMap.lookup path hash of
    Nothing -> do
      next' <- evaluate $ next + 1
      writeIORef filePathCacheRef (HashMap.insert path next' hash, next')
      return $ FilePathPtr next'
    Just key ->
      return $ FilePathPtr key

-- | Construct the explicit sharing cache
--
-- NOTE: This wipes the IdPropCache. This should only be called at the end
-- of a compile cycle.
constructExplicitSharingCache :: IO ExplicitSharingCache
constructExplicitSharingCache = do
    -- TODO: keep two refs and wipe on that for local ids, to avoid blowup
    -- for long-running sessions with many added and removed definitions.
    idPropCache <- readIORef idPropCacheRef
    liftIO $ writeIORef idPropCacheRef IntMap.empty

    (filePathHash, _) <- readIORef filePathCacheRef
    let filePathCache = IntMap.fromList . map convert $ HashMap.toList filePathHash

    return ExplicitSharingCache {..}
  where
    convert :: (FilePath, Int) -> (Int, ByteString)
    convert (path, i) = (i, BSSC.pack path)

{------------------------------------------------------------------------------
  Environment mapping source locations to info
------------------------------------------------------------------------------}

fromGhcNameSpace :: Name.NameSpace -> IdNameSpace
fromGhcNameSpace ns
  | ns == Name.varName  = VarName
  | ns == Name.dataName = DataName
  | ns == Name.tvName   = TvName
  | ns == Name.tcName   = TcClsName
  | otherwise = error "fromGhcNameSpace"

{------------------------------------------------------------------------------
  Extract an IdMap from information returned by the ghc type checker
------------------------------------------------------------------------------}

qqRef :: StrictIORef IdList
{-# NOINLINE qqRef #-}
qqRef = unsafePerformIO $ newIORef []

extractIdsPlugin :: StrictIORef (Strict (Map ModuleName) IdList) -> HscPlugin
extractIdsPlugin symbolRef = HscPlugin {..}
  where
    runHscQQ :: forall m. MonadIO m => Env TcGblEnv TcLclEnv
                                    -> HsQuasiQuote Name
                                    -> m (HsQuasiQuote Name)
    runHscQQ env qq@(HsQuasiQuote quoter _span _str) = liftIO $ do
      appendFile "/tmp/ghc.qq" $ showSDoc (ppr qq)
      idInfo <- readIORef qqRef
      ProperSpan span' <- extractSourceSpan $ tcl_loc (env_lcl env)
      let dflags = hsc_dflags  (env_top env)
          rdrEnv = tcg_rdr_env (env_gbl env)
      (idProp, Just idScope) <- idInfoForName dflags
                                              quoter
                                              False
                                              (lookupRdrEnv rdrEnv quoter)
      let quoterInfo = IdInfo{..}
      let idInfo' = (span', SpanQQ quoterInfo) : idInfo
      writeIORef qqRef idInfo'
      return qq

    runHscPlugin :: forall m. MonadIO m => DynFlags -> TcGblEnv -> m TcGblEnv
    runHscPlugin dynFlags env = do
      let processedModule = tcg_mod env
          processedName   = Text.pack $ moduleNameString $ GHC.moduleName processedModule

      qqs <- liftIO $ do
        qqs <- readIORef qqRef
        writeIORef qqRef [] -- Reset for the next module
        return qqs

      identMap <- execExtractIdsT dynFlags (tcg_rdr_env env) qqs $ do
#if DEBUG
        pretty_mod     <- pretty False processedModule
        pretty_rdr_env <- pretty False (tcg_rdr_env env)
        liftIO $ writeFile "/tmp/ghc.readerenv" pretty_rdr_env
#endif

        -- Information provided by the renamer
        -- See http://www.haskell.org/pipermail/ghc-devs/2013-February/000540.html
        -- It is important we do this *first*, because this creates the initial
        -- cache with the IdInfo objects, which we can then update by processing
        -- the typed AST and the global type environment.
#if DEBUG
        liftIO $ appendFile "/tmp/ghc.log" $ "<<PROCESSING RENAMED AST " ++ pretty_mod ++ ">>\n"
#endif
        extractIds (tcg_rn_decls env)

        -- Information provided by the type checker
#if DEBUG
        liftIO $ appendFile "/tmp/ghc.log" $ "<<PROCESSING TYPED AST " ++ pretty_mod ++ ">>\n"
#endif
        extractIds (tcg_binds env)

        -- Type environment constructed for this module
#if DEBUG
        liftIO $ appendFile "/tmp/ghc.log" $ "<<PROCESSING TYPE ENV FOR " ++ pretty_mod ++ ">>\n"
#endif
        extractTypesFromTypeEnv (tcg_type_env env)

#if DEBUG
    --  liftIO $ writeFile "/tmp/ghc.idmap" (show identMap)
    -- liftIO $ do
    --    cache <- readIORef idPropCacheRef
    --    appendFile "/tmp/ghc.log" $ "Cache == " ++ show cache
#endif
      liftIO $ modifyIORef symbolRef (Map.insert processedName identMap)
      return env

extractTypesFromTypeEnv :: forall m. MonadIO m => TypeEnv -> ExtractIdsT m ()
extractTypesFromTypeEnv = mapM_ go . nameEnvUniqueElts
  where
    go :: (Unique, TyThing) -> ExtractIdsT m ()
    go (uniq, ADataCon dataCon) =
      recordType ("ADataCon: " ++ showSDoc (ppr dataCon)) uniq (dataConRepType dataCon)
    go _ =
      return ()

{------------------------------------------------------------------------------
  ExtractIdsT adds state and en environment to whatever monad that GHC
  puts us in (this is why it needs to be a monad transformer).

  Note that MonadIO is GHC's MonadIO, not the standard one, and hence we need
  our own instance.
------------------------------------------------------------------------------}

newtype ExtractIdsT m a = ExtractIdsT (
      ReaderT (DynFlags, RdrName.GlobalRdrEnv, PprStyle) (StrictStateT (TidyEnv, IdList) m) a
    )
  deriving (Functor, Monad, MonadState (TidyEnv, IdList), MonadReader (DynFlags, RdrName.GlobalRdrEnv, PprStyle))

execExtractIdsT :: Monad m => DynFlags -> RdrName.GlobalRdrEnv -> IdList -> ExtractIdsT m () -> m IdList
execExtractIdsT dynFlags rdrEnv idList (ExtractIdsT m) = do
  let qual = mkPrintUnqualified dynFlags rdrEnv
      pprStyle = mkUserStyle qual AllTheWay
  (_, idList') <- execStateT (runReaderT m (dynFlags, rdrEnv, pprStyle)) (emptyTidyEnv, idList)
  return idList'

instance MonadTrans ExtractIdsT where
  lift = ExtractIdsT . lift . lift

-- This is not the standard MonadIO, but the MonadIO from GHC!
instance MonadIO m => MonadIO (ExtractIdsT m) where
  liftIO = lift . liftIO

getDynFlags :: Monad m => ExtractIdsT m DynFlags
getDynFlags = asks $ \(dflags, _, _) -> dflags

getGlobalRdrEnv :: Monad m => ExtractIdsT m RdrName.GlobalRdrEnv
getGlobalRdrEnv = asks $ \(_, env, _) -> env

getPprStyle :: Monad m => ExtractIdsT m PprStyle
getPprStyle = asks $ \(_, _, pprStyle) -> pprStyle

extendIdMap :: MonadIO m => SourceSpan -> SpanInfo -> ExtractIdsT m ()
extendIdMap span info = modify (second aux)
  where
    aux :: IdList -> IdList
    aux = (:) (span, info)

tidyType :: Monad m => Type -> ExtractIdsT m Type
tidyType typ = state $ \(tidyEnv, idMap) ->
  let (tidyEnv', typ') = tidyOpenType tidyEnv typ
  in (typ', (tidyEnv', idMap))

lookupRdrEnv :: RdrName.GlobalRdrEnv -> Name -> Maybe RdrName.GlobalRdrElt
lookupRdrEnv rdrEnv name =
  case lookupOccEnv rdrEnv (Name.nameOccName name) of
    Nothing   -> Nothing
    Just elts -> case filter ((== name) . RdrName.gre_name) elts of
                   []    -> Nothing
                   [elt] -> Just elt
                   _     -> error "ghc invariant violated"

#if DEBUG
-- In ghc 7.4 showSDoc does not take the dynflags argument; for 7.6 and up
-- it does
pretty :: (Monad m, Outputable a) => Bool -> a -> ExtractIdsT m String
pretty debugShow val = do
  _dynFlags <- getDynFlags
#if __GLASGOW_HASKELL__ >= 706
  return $ (if debugShow then showSDocDebug else showSDoc) _dynFlags (ppr val)
#else
  return $ (if debugShow then showSDocDebug else showSDoc) (ppr val)
#endif
#endif

debugPP :: (MonadIO m, Outputable a) => String -> a -> ExtractIdsT m ()
#if DEBUG
debugPP header val = do
  val' <- pretty True val
  liftIO $ appendFile "/tmp/ghc.log" (header ++ ": " ++ val' ++ "\n")
#else
debugPP _ _ = return ()
#endif

-- We mark every node in the AST with 'ast'. This is necessary so that we can
-- restore the TidyEnv at every node, so that we can reuse type variables. For
-- instance
--
-- > foo (x, y) = x
-- > bar (x, y) = y
--
-- In this case, we can assign (t, t1) -> t and (t, t1) -> t1 as types, reusing
-- 't' and 't1', but we can only do this because they are not nested.
--
-- For debugging purposes, we also take in two arguments describing the AST.
--
-- TODO: This assumes that the structure of the AST follows Haskell scoping
-- rules.  If this is not the case, this will break.
ast :: MonadIO m => Maybe SrcSpan -> String -> ExtractIdsT m a -> ExtractIdsT m a
ast _mspan _info cont = do
#if DEBUG
  indent <- liftIO $ do
    indent <- readIORef astIndent
    appendFile "/tmp/ghc.log" $ replicate indent ' ' ++ _info ++ "\n"
    writeIORef astIndent (indent + 2)
    return indent
#endif

  (tidyEnv, _) <- get
  r <- cont
  (_, idMap') <- get
  put (tidyEnv, idMap')

#if DEBUG
  liftIO $ writeIORef astIndent indent
#endif

  return r

#if DEBUG
astIndent :: StrictIORef Int
{-# NOINLINE astIndent #-}
astIndent = unsafePerformIO $ newIORef 0
#endif

unsupported :: MonadIO m => Maybe SrcSpan -> String -> ExtractIdsT m ()
#if DEBUG
unsupported mspan c = ast mspan c $ do
  prettySpan <- pretty False mspan
  liftIO . appendFile "/tmp/ghc.log" $ "extractIds: unsupported " ++ c ++ " at " ++ prettySpan ++ "\n"
#else
unsupported _ _ = return ()
#endif

{------------------------------------------------------------------------------
  Record
------------------------------------------------------------------------------}

type IsBinder = Bool

class (Uniquable id, OutputableBndr id) => Record id where
  record :: MonadIO m => SrcSpan -> IsBinder -> id -> ExtractIdsT m ()

instance Record Id where
  record _span _idIsBinder id = recordType (showSDocDebug (ppr id)) (getUnique id) (Var.varType id)

recordType :: MonadIO m => String -> Unique -> Type -> ExtractIdsT m ()
recordType _header uniq typ = do
  typ' <- tidyType typ
  -- We don't want line breaks in the types
  pprStyle <- getPprStyle
  let noForalls = False
      typStr    = showDocWith OneLineMode
                   (runSDoc (pprTypeForUser noForalls typ')
                   (initSDocContext pprStyle))
#if DEBUG
  liftIO $ appendFile "/tmp/ghc.log" $ _header ++ ": recording " ++ typStr ++ " for unique " ++ show (getKey uniq) ++ "\n"
#endif
  let idPropPtr = IdPropPtr $ getKey uniq
  modifyIdPropCache idPropPtr $ \idInfo -> idInfo {
      idType = Maybe.just $ Text.pack typStr
    }

-- | Construct an IdInfo for a 'Name'. We assume the @GlobalRdrElt@ is
-- uniquely determined by the @Name@ and the @DynFlags@ do not change
-- in a bad way.
idInfoForName :: MonadIO m
              => DynFlags                      -- ^ The usual dynflags
              -> Name                          -- ^ The name in question
              -> Bool                          -- ^ Is this a binding occurrence?
              -> Maybe RdrName.GlobalRdrElt    -- ^ GlobalRdrElt for imported names
              -> m (IdPropPtr, Maybe IdScope)  -- ^ Nothing if imported but no GlobalRdrElt
idInfoForName dflags name idIsBinder mElt = do
    scope <- constructScope
    let idPropPtr = IdPropPtr . getKey . getUnique $ name
    extendIdPropCache idPropPtr IdProp{..}
    return (idPropPtr, scope)
  where
      occ     = Name.nameOccName name
      idName  = Text.pack $ Name.occNameString occ
      idSpace = fromGhcNameSpace $ Name.occNameSpace occ
      idType  = Maybe.nothing  -- after renamer but before typechecker

      constructScope :: MonadIO m => m (Maybe IdScope)
      constructScope
        | idIsBinder               = return $ Just Binder
        | Name.isWiredInName  name = return $ Just WiredIn
        | Name.isInternalName name = do
            span <- extractSourceSpan (Name.nameSrcSpan name)
            return . Just $ Local {
                idDefSpan = span
              }
        | otherwise = case mElt of
              Just gre -> do scope <- scopeFromProv (RdrName.gre_prov gre)
                             return (Just scope)
              Nothing  -> return Nothing

      scopeFromProv :: MonadIO m => RdrName.Provenance -> m IdScope
      scopeFromProv RdrName.LocalDef = do
        span <- extractSourceSpan (Name.nameSrcSpan name)
        return Local {
            idDefSpan = span
          }
      scopeFromProv (RdrName.Imported spec) = do
        let mod = fromMaybe
                    (error (concatMap showSDocDebug $ ppr name : map ppr spec))
                    $ Name.nameModule_maybe name
        (impMod, impSpan, impQual) <- extractImportInfo spec
        span <- extractSourceSpan (Name.nameSrcSpan name)
        return Imported {
            idDefSpan      = span
          , idDefinedIn    = ModuleId
              { moduleName    = Text.pack $ moduleNameString $ Module.moduleName mod
              , modulePackage = fillVersion dflags $ Module.modulePackageId mod
              }
          , idImportedFrom = moduleNameToId dflags impMod
          , idImportSpan   = impSpan
          , idImportQual   = Text.pack $ impQual
          }

      extractImportInfo :: MonadIO m => [RdrName.ImportSpec] -> m (GHC.ModuleName, EitherSpan, String)
      extractImportInfo (RdrName.ImpSpec decl item:_) = do
        span <- case item of
                  RdrName.ImpAll -> extractSourceSpan (RdrName.is_dloc decl)
                  RdrName.ImpSome _explicit loc -> extractSourceSpan loc
        return
          ( RdrName.is_mod decl
          , span
          , if RdrName.is_qual decl
              then moduleNameString (RdrName.is_as decl) ++ "."
              else ""
          )
      extractImportInfo _ = fail "ghc invariant violated"

moduleNameToId :: DynFlags -> GHC.ModuleName -> ModuleId
moduleNameToId dflags impMod = ModuleId {
      moduleName    = Text.pack $ moduleNameString $ impMod
    , modulePackage = packageId
    }
  where
    -- | Translate a module name to a PackageId (i.e., add package information)
    packageId :: PackageId
    packageId = case pkgExposed of
      []  -> mainPackage  -- we assume otherwise GHC would signal an error
      [p] -> fillVersion dflags $ Packages.packageConfigId $ fst p
      _   -> let pkgIds = map (first (Module.packageIdString
                                       . Packages.packageConfigId)) pkgExposed
             in error $ "modToPkg: " ++ moduleNameString impMod
                     ++ ": " ++ show pkgIds

    pkgAll     = Packages.lookupModuleInAllPackages dflags impMod
    pkgExposed = filter (\ (p, b) -> b && Packages.exposed p) pkgAll

-- | Attempt to find out the version of a package
fillVersion :: DynFlags -> Module.PackageId -> PackageId
fillVersion dflags p =
  case Packages.lookupPackage (Packages.pkgIdMap (pkgState dflags)) p of
    Nothing -> if p == Module.mainPackageId
               then mainPackage
               else error $ "fillVersion:" ++ Module.packageIdString p
    Just pkgCfg ->
      let sourcePkgId = Packages.sourcePackageId pkgCfg
          pkgName = Packages.pkgName sourcePkgId
          prefixPN = "PackageName "
          showPN = show pkgName
          -- A hack to avoid importing Distribution.Package.
          errPN = fromMaybe (error $ "stripPrefixPN "
                                     ++ prefixPN ++ " "
                                     ++ showPN)
                  $ stripPrefix prefixPN showPN
          packageName = init $ tail errPN
          pkgVersion  = Packages.pkgVersion sourcePkgId
          packageVersion = Maybe.just $ case showVersion pkgVersion of
            -- See http://www.haskell.org/ghc/docs/7.4.2//html/libraries/ghc/Module.html#g:3.
            -- The version of wired-in packages is completely wiped out,
            -- but we use a leak in the form of a Cabal package id
            -- for the same package, which still contains a version.
            "" -> let installedPkgId = Packages.installedPackageId pkgCfg
                      prefixPV = "InstalledPackageId "
                                 ++ "\"" ++ packageName ++ "-"
                      showPV = show installedPkgId
                      -- A hack to avoid cabal dependency, in particular.
                      errPV = fromMaybe (error $ "stripPrefixPV "
                                                 ++ prefixPV ++ " "
                                                 ++ showPV)
                              $ stripPrefix prefixPV showPV
                  in reverse $ tail $ snd $ break (=='-') $ reverse errPV
            s  -> s
      in PackageId {
             packageName    = Text.pack packageName
           , packageVersion = Text.pack <$> packageVersion
           }

-- | PackageId of the main package
mainPackage :: PackageId
mainPackage = PackageId {
    packageName    = Text.pack $ Module.packageIdString Module.mainPackageId
  , packageVersion = Maybe.nothing -- the only case of no version
  }

extractSourceSpan :: MonadIO m => SrcSpan -> m EitherSpan
extractSourceSpan (RealSrcSpan srcspan) = liftIO $ do
  key <- mkFilePathPtr $ unpackFS (srcSpanFile srcspan)
  return . ProperSpan $ SourceSpan
    key
    (srcSpanStartLine srcspan) (srcSpanStartCol srcspan)
    (srcSpanEndLine srcspan)   (srcSpanEndCol   srcspan)
extractSourceSpan (UnhelpfulSpan s) =
  return . TextSpan $ fsToText s

instance Record Name where
  record span idIsBinder name = do
    span' <- extractSourceSpan span
    case span' of
      ProperSpan sourceSpan -> do
        dflags <- getDynFlags
        rdrEnv <- getGlobalRdrEnv
        -- The lookup into the rdr env will only be used for imported names.
        -- TODO: the cache is update twice here; clean up with Ints in IdMaps.
        info <- idInfoForName dflags name idIsBinder (lookupRdrEnv rdrEnv name)
        case info of
          (idProp, Just idScope) -> do
            extendIdMap sourceSpan $ SpanId IdInfo{..}
          _ ->
            -- This only happens for some special cases ('assert' being
            -- the prime example; it gets reported as 'assertError' from
            -- 'GHC.IO.Exception' but there is no corresponding entry in the
            -- GlobalRdrEnv.
            return ()
      TextSpan _ ->
        debugPP "Name without source span" name

{------------------------------------------------------------------------------
  ExtractIds
------------------------------------------------------------------------------}

class ExtractIds a where
  extractIds :: MonadIO m => a -> ExtractIdsT m ()

instance ExtractIds a => ExtractIds [a] where
  extractIds = mapM_ extractIds

instance ExtractIds a => ExtractIds (Maybe a) where
  extractIds Nothing  = return ()
  extractIds (Just x) = extractIds x

instance Record id => ExtractIds (HsGroup id) where
  extractIds HsGroup { hs_valds
                     , hs_tyclds
                     , hs_instds
                     , hs_derivds
                     , hs_fixds
                     , hs_defds
                     , hs_fords
                     , hs_warnds
                     , hs_annds
                     , hs_ruleds
                     , hs_vects
                     , hs_docs} = ast Nothing "HsGroup" $ do
    extractIds hs_valds
    extractIds hs_tyclds
    extractIds hs_instds
    extractIds hs_derivds
    extractIds hs_fixds
    extractIds hs_defds
    extractIds hs_fords
    extractIds hs_warnds
    extractIds hs_annds
    extractIds hs_ruleds
    extractIds hs_vects
    extractIds hs_docs

instance Record id => ExtractIds (HsValBinds id) where
  extractIds (ValBindsIn {}) =
    fail "extractIds: Unexpected ValBindsIn"
  extractIds (ValBindsOut binds sigs) = ast Nothing "ValBindsOut" $ do
    extractIds (map snd binds)
    extractIds sigs

instance Record id => ExtractIds (LSig id) where
  extractIds (L span (TypeSig names tp)) = ast (Just span) "TypeSig" $ do
    forM_ names $ \name -> record (getLoc name) False (unLoc name)
    extractIds tp
  extractIds (L span (GenericSig names tp)) = ast (Just span) "GenericSig" $ do
    forM_ names $ \name -> record (getLoc name) False (unLoc name)
    extractIds tp

  -- Only in generated code
  extractIds (L span (IdSig _)) = ast (Just span) "IdSig" $
    return ()

  -- Annotations
  extractIds (L span (FixSig _)) = ast (Just span) "FixSig" $
    return ()
  extractIds (L span (InlineSig _ _)) = ast (Just span) "InlineSig" $
    return ()
  extractIds (L span (SpecSig _ _ _)) = ast (Just span) "SpecSig" $
    return ()
  extractIds (L span (SpecInstSig _)) = ast (Just span) "SpecInstSig" $
    return ()

instance Record id => ExtractIds (LHsType id) where
  extractIds (L span (HsFunTy arg res)) = ast (Just span) "HsFunTy" $
    extractIds [arg, res]
  extractIds (L span (HsTyVar name)) = ast (Just span) "HsTyVar" $
    record span False name
  extractIds (L span (HsForAllTy _explicitFlag tyVars ctxt body)) = ast (Just span) "hsForAllTy" $ do
    extractIds tyVars
    extractIds ctxt
    extractIds body
  extractIds (L span (HsAppTy fun arg)) = ast (Just span) "HsAppTy" $
    extractIds [fun, arg]
  extractIds (L span (HsTupleTy _tupleSort typs)) = ast (Just span) "HsTupleTy" $
    -- tupleSort is unboxed/boxed/etc.
    extractIds typs
  extractIds (L span (HsListTy typ)) = ast (Just span) "HsListTy" $
    extractIds typ
  extractIds (L span (HsPArrTy typ)) = ast (Just span) "HsPArrTy" $
    extractIds typ
  extractIds (L span (HsParTy typ)) = ast (Just span) "HsParTy" $
    extractIds typ
  extractIds (L span (HsEqTy a b)) = ast (Just span) "HsEqTy" $
    extractIds [a, b]
  extractIds (L span (HsDocTy typ _doc)) = ast (Just span) "HsDocTy" $
    -- I don't think HsDocTy actually makes it through the renamer
    extractIds typ
  extractIds (L span (HsWrapTy _wrapper _typ)) = ast (Just span) "HsWrapTy" $
    -- This is returned only by the type checker, and _typ is not located
    return ()
  extractIds (L span (HsRecTy fields)) = ast (Just span) "HsRecTy" $
    extractIds fields
  extractIds (L span (HsKindSig typ kind)) = ast (Just span) "HsKindSig" $
    extractIds [typ, kind]
  extractIds (L span (HsBangTy _bang typ)) = ast (Just span) "HsBangTy" $
    extractIds typ
  extractIds (L span (HsOpTy left (_wrapper, op) right)) = ast (Just span) "HsOpTy" $ do
    extractIds [left, right]
    record (getLoc op) False (unLoc op)
  extractIds (L span (HsIParamTy _var typ)) = ast (Just span) "HsIParamTy" $
    -- _var is not located
    extractIds typ
  extractIds (L span (HsSpliceTy splice _freevars _postTcKind)) = ast (Just span) "HsSpliceTy" $
    extractIds (L span splice) -- reuse location info
  extractIds (L span (HsCoreTy _)) = ast (Just span) "HsCoreTy" $
    -- Not important: doesn't arise until later in the compiler pipeline
    return ()
  extractIds (L span (HsQuasiQuoteTy qquote))  = ast (Just span) "HsQuasiQuoteTy" $
    extractIds (L span qquote) -- reuse location info
  extractIds (L span (HsExplicitListTy _postTcKind typs)) = ast (Just span) "HsExplicitListTy" $
    extractIds typs
  extractIds (L span (HsExplicitTupleTy _postTcKind typs)) = ast (Just span) "HsExplicitTupleTy" $
    extractIds typs

#if __GLASGOW_HASKELL__ >= 706
  -- TODO: Type literals
  extractIds (L span (HsTyLit _))             = unsupported (Just span) "HsTyLit"
#endif

instance Record id => ExtractIds (Located (HsSplice id)) where
  extractIds (L span (HsSplice _id expr)) = ast (Just span) "HsSplice" $
    extractIds expr

instance Record id => ExtractIds (Located (HsQuasiQuote id)) where
  extractIds (L span (HsQuasiQuote _id _srcSpan _enclosed)) = ast (Just span) "HsQuasiQuote" $
    -- Unfortunately, no location information is stored within HsQuasiQuote at all
    return ()

#if __GLASGOW_HASKELL__ >= 706
instance Record id => ExtractIds (LHsTyVarBndrs id) where
  extractIds (HsQTvs _kvs tvs) = ast Nothing "HsQTvs" $ do
    -- We don't have location info for the kind variables
    extractIds tvs
#endif

instance Record id => ExtractIds (LHsTyVarBndr id) where
#if __GLASGOW_HASKELL__ >= 706
  extractIds (L span (UserTyVar name)) = ast (Just span) "UserTyVar" $ do
#else
  extractIds (L span (UserTyVar name _postTcKind)) = ast (Just span) "UserTyVar" $ do
#endif
    record span True name

#if __GLASGOW_HASKELL__ >= 706
  extractIds (L span (KindedTyVar name kind)) = ast (Just span) "KindedTyVar" $ do
#else
  extractIds (L span (KindedTyVar name kind _postTcKind)) = ast (Just span) "KindedTyVar" $ do
#endif
    record span True name
    extractIds kind

instance Record id => ExtractIds (LHsContext id) where
  extractIds (L span typs) = ast (Just span) "LHsContext" $
    extractIds typs

instance Record id => ExtractIds (LHsBinds id) where
  extractIds = extractIds . bagToList

instance Record id => ExtractIds (LHsBind id) where
  extractIds (L span bind@(FunBind {})) = ast (Just span) "FunBind" $ do
    record (getLoc (fun_id bind)) True (unLoc (fun_id bind))
    extractIds (fun_matches bind)
  extractIds (L span bind@(PatBind {})) = ast (Just span) "PatBind" $ do
    extractIds (pat_lhs bind)
    extractIds (pat_rhs bind)
  extractIds (L span _bind@(VarBind {})) = ast (Just span) "VarBind" $
    -- These are only introduced by the type checker, and don't involve user
    -- written code. The ghc comments says "located 'only for consistency'"
    return ()
  extractIds (L span bind@(AbsBinds {})) = ast (Just span) "AbsBinds" $ do
    forM_ (abs_exports bind) $ \abs_export ->
      record (UnhelpfulSpan (error "we never look at this span")) True (abe_poly abs_export)
    extractIds (abs_binds bind)

#if __GLASGOW_HASKELL__ >= 707
instance (ExtractIds body, Record id) => ExtractIds (MatchGroup id body) where
  extractIds (MG matches _argTys _resTy) = ast Nothing "MatchGroup" $
    extractIds matches
#else
instance Record id => ExtractIds (MatchGroup id) where
  -- We ignore the postTcType, as it doesn't have location information
  extractIds (MatchGroup matches _postTcType) = ast Nothing "MatchGroup" $
    extractIds matches
#endif

#if __GLASGOW_HASKELL__ >= 707
instance (ExtractIds body, Record id) => ExtractIds (LMatch id body) where
#else
instance Record id => ExtractIds (LMatch id) where
#endif
  extractIds (L span (Match pats _type rhss)) = ast (Just span) "Match" $ do
    extractIds pats
    extractIds rhss

#if __GLASGOW_HASKELL__ >= 707
instance (ExtractIds body, Record id) => ExtractIds (GRHSs id body) where
#else
instance Record id => ExtractIds (GRHSs id) where
#endif
  extractIds (GRHSs rhss binds) = ast Nothing "GRHSs" $ do
    extractIds rhss
    extractIds binds

#if __GLASGOW_HASKELL__ >= 707
instance (ExtractIds body, Record id) => ExtractIds (LGRHS id body) where
#else
instance Record id => ExtractIds (LGRHS id) where
#endif
  extractIds (L span (GRHS _guards rhs)) = ast (Just span) "GRHS" $
    extractIds rhs

instance Record id => ExtractIds (HsLocalBinds id) where
  extractIds EmptyLocalBinds =
    return ()
  extractIds (HsValBinds (ValBindsIn _ _)) =
    fail "extractIds: Unexpected ValBindsIn (after renamer these should not exist)"
  extractIds (HsValBinds (ValBindsOut binds sigs)) = ast Nothing "HsValBinds" $ do
    extractIds (map snd binds) -- "fst" is 'rec flag'
    extractIds sigs
  extractIds (HsIPBinds binds) =
    extractIds binds

instance Record id => ExtractIds (HsIPBinds id) where
  extractIds (IPBinds binds _evidence) =
    extractIds binds

instance Record id => ExtractIds (LIPBind id) where
  extractIds (L span (IPBind _name expr)) = ast (Just span) "IPBind" $ do
    -- Name is not located :(
    extractIds expr

instance Record id => ExtractIds (LHsExpr id) where
  extractIds (L span (HsPar expr)) = ast (Just span) "HsPar" $
    extractIds expr
  extractIds (L span (ExprWithTySig expr _type)) = ast (Just span) "ExprWithTySig" $
    extractIds expr
  extractIds (L span (ExprWithTySigOut expr _type)) = ast (Just span) "ExprWithTySigOut" $
    extractIds expr
  extractIds (L span (HsOverLit _ )) = ast (Just span) "HsOverLit" $
    return ()
  extractIds (L span (OpApp left op _fix right)) = ast (Just span) "OpApp" $
    extractIds [left, op, right]
  extractIds (L span (HsVar id)) = ast (Just span) "HsVar" $
    record span False id
  extractIds (L span (HsWrap _wrapper expr)) = ast (Just span) "HsWrap" $
    extractIds (L span expr)
  extractIds (L span (HsLet binds expr)) = ast (Just span) "HsLet" $ do
    extractIds binds
    extractIds expr
  extractIds (L span (HsApp fun arg)) = ast (Just span) "HsApp" $
    extractIds [fun, arg]
  extractIds (L _span (HsLit _)) =
    -- Intentional omission of the "ast" debugging call here.
    -- The syntax "assert" is replaced by GHC by "assertError <span>", where
    -- both "assertError" and the "<span>" are assigned the source span of
    -- the original "assert". This means that the <span> (represented as an
    -- HsLit) might override "assertError" in the IdMap.
    return ()
  extractIds (L span (HsLam matches)) = ast (Just span) "HsLam" $
    extractIds matches
  extractIds (L span (HsDo _ctxt stmts _postTcType)) = ast (Just span) "HsDo" $
    -- ctxt indicates what kind of statement it is; AFAICT there is no
    -- useful information in it for us
    -- postTcType is not located
    extractIds stmts
#if __GLASGOW_HASKELL__ >= 707
  -- Middle argument is something to do with OverloadedLists
  extractIds (L span (ExplicitList _postTcType _ exprs)) = ast (Just span) "ExplicitList" $
    extractIds exprs
#else
  extractIds (L span (ExplicitList _postTcType exprs)) = ast (Just span) "ExplicitList" $
    extractIds exprs
#endif
  extractIds (L span (RecordCon con _postTcType recordBinds)) = ast (Just span) "RecordCon" $ do
    record (getLoc con) False (unLoc con)
    extractIds recordBinds
  extractIds (L span (HsCase expr matches)) = ast (Just span) "HsCase" $ do
    extractIds expr
    extractIds matches
  extractIds (L span (ExplicitTuple args _boxity)) = ast (Just span) "ExplicitTuple" $
    extractIds args
  extractIds (L span (HsIf _rebind cond true false)) = ast (Just span) "HsIf" $
    extractIds [cond, true, false]
  extractIds (L span (SectionL arg op)) = ast (Just span) "SectionL" $
    extractIds [arg, op]
  extractIds (L span (SectionR op arg)) = ast (Just span) "SectionR" $
    extractIds [op, arg]
  extractIds (L span (HsIPVar _name)) = ast (Just span) "HsIPVar" $
    -- _name is not located :(
    return ()
  extractIds (L span (NegApp expr _rebind)) = ast (Just span) "NegApp" $
    extractIds expr
  extractIds (L span (HsBracket th)) = ast (Just span) "HsBracket" $
    extractIds th
  extractIds (L span (HsBracketOut th _pendingSplices)) = ast (Just span) "HsBracketOut" $
    -- TODO: should we traverse pendingSplices?
    extractIds th
  extractIds (L span (RecordUpd expr binds _dataCons _postTcTypeInp _postTcTypeOutp)) = ast (Just span) "RecordUpd" $ do
    extractIds expr
    extractIds binds
  extractIds (L span (HsProc pat body)) = ast (Just span) "HsProc" $ do
    extractIds pat
    extractIds body
  extractIds (L span (HsArrApp arr inp _postTcType _arrType _orient)) = ast (Just span) "HsArrApp" $ do
    extractIds [arr, inp]
  extractIds (L span (HsArrForm expr _fixity cmds)) = ast (Just span) "HsArrForm" $ do
    extractIds expr
    extractIds cmds
  extractIds (L span (HsTick _tickish expr)) = ast (Just span) "HsTick" $ do
    extractIds expr
  extractIds (L span (HsBinTick _trueTick _falseTick expr)) = ast (Just span) "HsBinTick" $ do
    extractIds expr
  extractIds (L span (HsTickPragma _span expr)) = ast (Just span) "HsTickPragma" $ do
    extractIds expr
  extractIds (L span (HsSCC _string expr)) = ast (Just span) "HsSCC" $ do
    extractIds expr
  extractIds (L span (HsCoreAnn _string expr)) = ast (Just span) "HsCoreAnn" $ do
    extractIds expr
  extractIds (L span (HsSpliceE splice)) = ast (Just span) "HsSpliceE" $ do
    extractIds (L span splice) -- reuse span
  extractIds (L span (HsQuasiQuoteE qquote)) = ast (Just span) "HsQuasiQuoteE" $ do
    extractIds (L span qquote) -- reuse span
  extractIds (L span (ExplicitPArr _postTcType exprs)) = ast (Just span) "ExplicitPArr" $ do
    extractIds exprs
  extractIds (L span (PArrSeq _postTcType seqInfo)) = ast (Just span) "PArrSeq" $ do
    extractIds seqInfo

  -- According to the comments in HsExpr.lhs,
  -- "These constructors only appear temporarily in the parser.
  -- The renamer translates them into the Right Thing."
  extractIds (L span EWildPat) = ast (Just span) "EWildPat" $
    return ()
  extractIds (L span (EAsPat _ _)) = ast (Just span) "EAsPat" $
    return ()
  extractIds (L span (EViewPat _ _)) = ast (Just span) "EViewPat" $
    return ()
  extractIds (L span (ELazyPat _)) = ast (Just span) "ELazyPat" $
    return ()
  extractIds (L span (HsType _ )) = ast (Just span) "HsType" $
    return ()

#if __GLASGOW_HASKELL__ >= 707
  -- Second argument is something to do with OverloadedLists
  extractIds (L span (ArithSeq _ _ _))      = unsupported (Just span) "ArithSeq"
#else
  extractIds (L span (ArithSeq _postTcExpr seqInfo)) = ast (Just span) "ArithSeq" $ do
    extractIds seqInfo
#endif

#if __GLASGOW_HASKELL__ >= 706
  extractIds (L span (HsLamCase _ _ ))      = unsupported (Just span) "HsLamCase"
  extractIds (L span (HsMultiIf _ _))       = unsupported (Just span) "HsMultiIf"
#endif

#if __GLASGOW_HASKELL__ >= 707
  extractIds (L span (HsUnboundVar _))      = unsupported (Just span) "HsUnboundVar"
#endif

instance Record id => ExtractIds (ArithSeqInfo id) where
  extractIds (From expr) = ast Nothing "From" $
    extractIds expr
  extractIds (FromThen frm thn) = ast Nothing "FromThen" $
    extractIds [frm, thn]
  extractIds (FromTo frm to) = ast Nothing "FromTo" $
    extractIds [frm, to]
  extractIds (FromThenTo frm thn to) = ast Nothing "FromThenTo" $
    extractIds [frm, thn, to]

instance Record id => ExtractIds (LHsCmdTop id) where
  extractIds (L span (HsCmdTop cmd _postTcTypeInp _postTcTypeRet _syntaxTable)) = ast (Just span) "HsCmdTop" $
    extractIds cmd

instance Record id => ExtractIds (HsBracket id) where
  extractIds (ExpBr expr) = ast Nothing "ExpBr" $
    extractIds expr
  extractIds (PatBr pat) = ast Nothing "PatBr" $
    extractIds pat
  extractIds (DecBrG group) = ast Nothing "DecBrG" $
    extractIds group
  extractIds (TypBr typ) = ast Nothing "TypBr" $
    extractIds typ
  extractIds (VarBr _namespace _id) = ast Nothing "VarBr" $
    -- No location information, sadly
    return ()
  extractIds (DecBrL decls) = ast Nothing "DecBrL" $
    extractIds decls

instance Record id => ExtractIds (HsTupArg id) where
  extractIds (Present arg) =
    extractIds arg
  extractIds (Missing _postTcType) =
    return ()

instance (ExtractIds a, Record id) => ExtractIds (HsRecFields id a) where
  extractIds (HsRecFields rec_flds _rec_dotdot) = ast Nothing "HsRecFields" $
    extractIds rec_flds

instance (ExtractIds a, Record id) => ExtractIds (HsRecField id a) where
  extractIds (HsRecField id arg _pun) = ast Nothing "HsRecField" $ do
    record (getLoc id) False (unLoc id)
    extractIds arg

-- The meaning of the constructors of LStmt isn't so obvious; see various
-- notes in ghc/compiler/hsSyn/HsExpr.lhs
#if __GLASGOW_HASKELL__ >= 707
instance (ExtractIds body, Record id) => ExtractIds (LStmt id body) where
  extractIds (L span (BodyStmt body _seq _guard _postTcType)) = ast (Just span) "BodyStmt" $
    extractIds body
#else
instance Record id => ExtractIds (LStmt id) where
  extractIds (L span (ExprStmt expr _seq _guard _postTcType)) = ast (Just span) "ExprStmt" $
    -- Neither _seq nor _guard are located
    extractIds expr
#endif
  extractIds (L span (BindStmt pat expr _bind _fail)) = ast (Just span) "BindStmt" $ do
    -- Neither _bind or _fail are located
    extractIds pat
    extractIds expr
  extractIds (L span (LetStmt binds)) = ast (Just span) "LetStmt" $
    extractIds binds
  extractIds (L span (LastStmt expr _return)) = ast (Just span) "LastStmt" $
    extractIds expr
  extractIds (L span stmt@(RecStmt {})) = ast (Just span) "RecStmt" $ do
    extractIds (recS_stmts stmt)

  extractIds (L span (TransStmt {}))     = unsupported (Just span) "TransStmt"
#if __GLASGOW_HASKELL__ >= 706
  extractIds (L span (ParStmt _ _ _))    = unsupported (Just span) "ParStmt"
#else
  extractIds (L span (ParStmt _ _ _ _))  = unsupported (Just span) "ParStmt"
#endif

instance Record id => ExtractIds (LPat id) where
  extractIds (L span (WildPat _postTcType)) = ast (Just span) "WildPat" $
    return ()
  extractIds (L span (VarPat id)) = ast (Just span) "VarPat" $
    record span True id
  extractIds (L span (LazyPat pat)) = ast (Just span) "LazyPat" $
    extractIds pat
  extractIds (L span (AsPat id pat)) = ast (Just span) "AsPat" $ do
    record (getLoc id) True (unLoc id)
    extractIds pat
  extractIds (L span (ParPat pat)) = ast (Just span) "ParPat" $
    extractIds pat
  extractIds (L span (BangPat pat)) = ast (Just span) "BangPat" $
    extractIds pat
#if __GLASGOW_HASKELL__ >= 707
  extractIds (L span (ListPat pats _postTcType _rebind)) = ast (Just span) "ListPat" $
    extractIds pats
#else
  extractIds (L span (ListPat pats _postTcType)) = ast (Just span) "ListPat" $
    extractIds pats
#endif
  extractIds (L span (TuplePat pats _boxity _postTcType)) = ast (Just span) "TuplePat" $
    extractIds pats
  extractIds (L span (PArrPat pats _postTcType)) = ast (Just span) "PArrPat" $
    extractIds pats
  extractIds (L span (ConPatIn con details)) = ast (Just span) "ConPatIn" $ do
    -- Unlike ValBindsIn and HsValBindsIn, we *do* get ConPatIn
    record (getLoc con) False (unLoc con) -- the constructor name is non-binding
    extractIds details
  extractIds (L span (ConPatOut {pat_con, pat_args})) = ast (Just span) "ConPatOut" $ do
    record (getLoc pat_con) False (dataConName (unLoc pat_con))
    extractIds pat_args
  extractIds (L span (LitPat _)) = ast (Just span) "LitPat" $
    return ()
  extractIds (L span (NPat _ _ _)) = ast (Just span) "NPat" $
    return ()
  extractIds (L span (NPlusKPat id _lit _rebind1 _rebind2)) = ast (Just span) "NPlusKPat" $ do
    record (getLoc id) True (unLoc id)
  extractIds (L span (ViewPat expr pat _postTcType)) = ast (Just span) "ViewPat" $ do
    extractIds expr
    extractIds pat
  extractIds (L span (SigPatIn pat typ)) = ast (Just span) "SigPatIn" $ do
    extractIds pat
    extractIds typ
  extractIds (L span (SigPatOut pat _typ)) = ast (Just span) "SigPatOut" $ do
    -- _typ is not located
    extractIds pat
  extractIds (L span (QuasiQuotePat qquote)) = ast (Just span) "QuasiQuotePat" $
    extractIds (L span qquote) -- reuse span

  -- During translation only
  extractIds (L span (CoPat _ _ _)) = ast (Just span) "CoPat" $
    return ()

instance (ExtractIds arg, ExtractIds rec) => ExtractIds (HsConDetails arg rec) where
  extractIds (PrefixCon args) = ast Nothing "PrefixCon" $
    extractIds args
  extractIds (RecCon rec) = ast Nothing "RecCon" $
    extractIds rec
  extractIds (InfixCon a b) = ast Nothing "InfixCon" $
    extractIds [a, b]

instance Record id => ExtractIds (LTyClDecl id) where
  extractIds (L span decl@(TyData {})) = ast (Just span) "TyData" $ do
    extractIds (tcdCtxt decl)
    record (getLoc (tcdLName decl)) True (unLoc (tcdLName decl))
    extractIds (tcdTyVars decl)
    extractIds (tcdTyPats decl)
    extractIds (tcdKindSig decl)
    extractIds (tcdCons decl)
    extractIds (tcdDerivs decl)
  extractIds (L span decl@(ClassDecl {})) = ast (Just span) "ClassDecl" $ do
    extractIds (tcdCtxt decl)
    record (getLoc (tcdLName decl)) True (unLoc (tcdLName decl))
    extractIds (tcdTyVars decl)
    -- Sadly, we don't get location info for the functional dependencies
    extractIds (tcdSigs decl)
    extractIds (tcdATs decl)
    extractIds (tcdATDefs decl)
    extractIds (tcdDocs decl)

#if __GLASGOW_HASKELL__ >= 707
  extractIds (L span _decl@(SynDecl {}))     = unsupported (Just span) "TySynonym"
  extractIds (L span _decl@(FamDecl {}))     = unsupported (Just span) "TyFamily"
  extractIds (L span _decl@(DataDecl {}))    = unsupported (Just span) "DataDecl"
#else
  extractIds (L span decl@(TySynonym {})) = ast (Just span) "TySynonym" $ do
    record (getLoc (tcdLName decl)) True (unLoc (tcdLName decl))
    extractIds (tcdTyVars decl)
    extractIds (tcdTyPats decl)
    extractIds (tcdSynRhs decl)
  extractIds (L span decl@(TyFamily {})) = ast (Just span) "TyFamily" $  do
    record (getLoc (tcdLName decl)) True (unLoc (tcdLName decl))
    extractIds (tcdTyVars decl)
    extractIds (tcdKind decl)
#endif

  extractIds (L span _decl@(ForeignType {})) = unsupported (Just span) "ForeignType"

instance Record id => ExtractIds (LConDecl id) where
  extractIds (L span decl@(ConDecl {})) = ast (Just span) "ConDecl" $ do
    record (getLoc (con_name decl)) True (unLoc (con_name decl))
    extractIds (con_qvars decl)
    extractIds (con_cxt decl)
    extractIds (con_details decl)
    extractIds (con_res decl)

instance Record id => ExtractIds (ResType id) where
  extractIds ResTyH98 = ast Nothing "ResTyH98" $ do
    return () -- Nothing to do
  extractIds (ResTyGADT typ) = ast Nothing "ResTyGADT" $ do
    extractIds typ

instance Record id => ExtractIds (ConDeclField id) where
  extractIds (ConDeclField name typ _doc) = do
    record (getLoc name) True (unLoc name)
    extractIds typ

instance Record id => ExtractIds (LInstDecl id) where
  extractIds (L span (InstDecl typ binds sigs accTypes)) = ast (Just span) "LInstDecl" $ do
    extractIds typ
    extractIds binds
    extractIds sigs
    extractIds accTypes

instance Record id => ExtractIds (LDerivDecl id) where
  extractIds (L span (DerivDecl deriv_type)) = ast (Just span) "LDerivDecl" $ do
    extractIds deriv_type

instance Record id => ExtractIds (LFixitySig id) where
  extractIds (L span (FixitySig name _fixity)) = ast (Just span) "LFixitySig" $ do
    record (getLoc name) False (unLoc name)

instance Record id => ExtractIds (LDefaultDecl id) where
  extractIds (L span (DefaultDecl typs)) = ast (Just span) "LDefaultDecl" $ do
    extractIds typs

instance Record id => ExtractIds (LForeignDecl id) where
  extractIds (L span (ForeignImport name sig _coercion _import)) = ast (Just span) "ForeignImport" $ do
    record (getLoc name) True (unLoc name)
    extractIds sig
  extractIds (L span (ForeignExport name sig _coercion _export)) = ast (Just span) "ForeignExport" $ do
    record (getLoc name) False (unLoc name)
    extractIds sig

instance Record id => ExtractIds (LWarnDecl id) where
  extractIds (L span (Warning name _txt)) = ast (Just span) "Warning" $ do
    -- We use the span of the entire warning because we don't get location info for name
    record span False name

instance Record id => ExtractIds (LAnnDecl id) where
  extractIds (L span _) = unsupported (Just span) "LAnnDecl"

instance Record id => ExtractIds (LRuleDecl id) where
  extractIds (L span _) = unsupported (Just span) "LRuleDecl"

instance Record id => ExtractIds (LVectDecl id) where
  extractIds (L span _) = unsupported (Just span) "LVectDecl"

instance ExtractIds LDocDecl where
  extractIds (L span _) = ast (Just span) "LDocDec" $
    -- Nothing to do
    return ()

instance Record id => ExtractIds (Located (SpliceDecl id)) where
  extractIds (L span (SpliceDecl expr _explicit)) = ast (Just span) "SpliceDecl" $ do
    extractIds expr

-- LHsDecl is a wrapper around the various kinds of declarations; the wrapped
-- declarations don't have location information of themselves, so we reuse
-- the location info of the wrapper
instance Record id => ExtractIds (LHsDecl id) where
  extractIds (L span (TyClD tyClD)) = ast (Just span) "TyClD" $
    extractIds (L span tyClD)
  extractIds (L span (InstD instD)) = ast (Just span) "InstD" $
    extractIds (L span instD)
  extractIds (L span (DerivD derivD)) = ast (Just span) "DerivD" $
    extractIds (L span derivD)
  extractIds (L span (ValD valD)) = ast (Just span) "ValD" $
    extractIds (L span valD)
  extractIds (L span (SigD sigD)) = ast (Just span) "SigD" $
    extractIds (L span sigD)
  extractIds (L span (DefD defD)) = ast (Just span) "DefD" $
    extractIds (L span defD)
  extractIds (L span (ForD forD)) = ast (Just span) "ForD" $
    extractIds (L span forD)
  extractIds (L span (WarningD warningD)) = ast (Just span) "WarningD" $
    extractIds (L span warningD)
  extractIds (L span (AnnD annD)) = ast (Just span) "AnnD" $
    extractIds (L span annD)
  extractIds (L span (RuleD ruleD)) = ast (Just span) "RuleD" $
    extractIds (L span ruleD)
  extractIds (L span (VectD vectD)) = ast (Just span) "VectD" $
    extractIds (L span vectD)
  extractIds (L span (SpliceD spliceD)) = ast (Just span) "SpliceD" $
    extractIds (L span spliceD)
  extractIds (L span (DocD docD)) = ast (Just span) "DocD" $
    extractIds (L span docD)
  extractIds (L span (QuasiQuoteD quasiQuoteD)) = ast (Just span) "QuasiQuoteD" $
    extractIds (L span quasiQuoteD)

{------------------------------------------------------------------------------
  Auxiliary
------------------------------------------------------------------------------}

fsToText :: FastString -> Text
fsToText = Text.pack . unpackFS