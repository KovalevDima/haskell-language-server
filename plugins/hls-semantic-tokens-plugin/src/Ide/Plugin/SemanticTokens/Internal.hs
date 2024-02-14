{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE OverloadedLabels    #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE UnicodeSyntax       #-}

-- |
-- This module provides the core functionality of the plugin.
module Ide.Plugin.SemanticTokens.Internal (semanticTokensFull, getSemanticTokensRule, semanticConfigProperties, semanticTokensFullDelta) where

import           Control.Concurrent.STM                   (modifyTVar',
                                                           readTVar)
import           Control.Concurrent.STM.Stats             (atomically)
import           Control.Lens                             ((^.))
import           Control.Monad.Except                     (ExceptT, liftEither,
                                                           withExceptT)
import           Control.Monad.IO.Class                   (MonadIO (..))
import           Control.Monad.Trans                      (lift)
import           Control.Monad.Trans.Except               (runExceptT)
import qualified Data.Map.Strict                          as M
import           Data.Text                                (Text)
import qualified Data.Text                                as T
import           Development.IDE                          (Action,
                                                           GetDocMap (GetDocMap),
                                                           GetHieAst (GetHieAst),
                                                           HieAstResult (HAR, hieAst, hieModule, refMap),
                                                           IdeResult, IdeState,
                                                           NormalizedUri,
                                                           Priority (..),
                                                           Recorder, Rules,
                                                           WithPriority,
                                                           cmapWithPrio, define,
                                                           fromNormalizedFilePath,
                                                           hieKind, use_)
import           Development.IDE.Core.PluginUtils         (runActionE,
                                                           useWithStaleE)
import           Development.IDE.Core.PositionMapping     (idDelta)
import           Development.IDE.Core.Rules               (toIdeResult)
import           Development.IDE.Core.RuleTypes           (DocAndTyThingMap (..))
import           Development.IDE.Core.Shake               (ShakeExtras (..),
                                                           addPersistentRule,
                                                           getShakeExtras,
                                                           getVirtualFile,
                                                           useWithStale_)
import           Development.IDE.GHC.Compat               hiding (Warning)
import           Development.IDE.GHC.Compat.Util          (mkFastString)
import           Ide.Logger                               (logWith)
import           Ide.Plugin.Error                         (PluginError (PluginInternalError),
                                                           getNormalizedFilePathE,
                                                           handleMaybe,
                                                           handleMaybeM)
import           Ide.Plugin.SemanticTokens.Mappings
import           Ide.Plugin.SemanticTokens.Query
import           Ide.Plugin.SemanticTokens.SemanticConfig (mkSemanticConfigFunctions)
import           Ide.Plugin.SemanticTokens.Tokenize       (computeRangeHsSemanticTokenTypeList)
import           Ide.Plugin.SemanticTokens.Types
import           Ide.Types
import qualified Language.LSP.Protocol.Lens               as L
import           Language.LSP.Protocol.Message            (MessageResult,
                                                           Method (Method_TextDocumentSemanticTokensFull, Method_TextDocumentSemanticTokensFullDelta))
import           Language.LSP.Protocol.Types              (NormalizedFilePath,
                                                           SemanticTokens,
                                                           normalizedFilePathToUri,
                                                           type (|?) (InL, InR))
import           Prelude                                  hiding (span)
import qualified StmContainers.Map                        as STM


$mkSemanticConfigFunctions

-----------------------
---- the api
-----------------------

computeSemanticTokens :: Recorder (WithPriority SemanticLog) -> PluginId -> IdeState -> NormalizedFilePath -> ExceptT PluginError Action SemanticTokens
computeSemanticTokens recorder pid _ nfp = do
  config <- lift $ useSemanticConfigAction pid
  logWith recorder Debug (LogConfig config)
  semanticId <- lift getAndIncreaseSemanticTokensId
  (RangeHsSemanticTokenTypes {rangeSemanticList}, mapping) <- useWithStaleE GetSemanticTokens nfp
  withExceptT PluginInternalError $ liftEither $ rangeSemanticsSemanticTokens semanticId config mapping rangeSemanticList

semanticTokensFull :: Recorder (WithPriority SemanticLog) -> PluginMethodHandler IdeState 'Method_TextDocumentSemanticTokensFull
semanticTokensFull recorder state pid param = runActionE "SemanticTokens.semanticTokensFull" state computeSemanticTokensFullDelta
  where
    computeSemanticTokensFullDelta :: ExceptT PluginError Action (MessageResult Method_TextDocumentSemanticTokensFull)
    computeSemanticTokensFullDelta = do
      nfp <- getNormalizedFilePathE (param ^. L.textDocument . L.uri)
      items <- computeSemanticTokens recorder pid state nfp
      lift $ setSemanticTokens (normalizedFilePathToUri nfp) items
      return $ InL items


semanticTokensFullDelta :: Recorder (WithPriority SemanticLog) -> PluginMethodHandler IdeState 'Method_TextDocumentSemanticTokensFullDelta
semanticTokensFullDelta recorder state pid param = do
  nfp <- getNormalizedFilePathE (param ^. L.textDocument . L.uri)
  let previousVersionFromParam = param ^. L.previousResultId
  runActionE "SemanticTokens.semanticTokensFullDelta" state $ computeSemanticTokensFullDelta previousVersionFromParam recorder pid state nfp
  where
    computeSemanticTokensFullDelta :: Text -> Recorder (WithPriority SemanticLog) -> PluginId -> IdeState -> NormalizedFilePath -> ExceptT PluginError Action (MessageResult Method_TextDocumentSemanticTokensFullDelta)
    computeSemanticTokensFullDelta previousVersionFromParam recorder pid state nfp = do
      semanticTokens <- computeSemanticTokens recorder pid state nfp
      previousSemanticTokensMaybe <- lift $ getPreviousSemanticTokens (normalizedFilePathToUri nfp)
      lift $ setSemanticTokens (normalizedFilePathToUri nfp) semanticTokens
      case previousSemanticTokensMaybe of
          Nothing -> return $ InL semanticTokens
          Just previousSemanticTokens ->
              if Just previousVersionFromParam == previousSemanticTokens^.L.resultId
              then return $ InR $ InL $ makeSemanticTokensDeltaWithId (semanticTokens^.L.resultId) previousSemanticTokens semanticTokens
              else return $ InL semanticTokens

-- | Defines the 'getSemanticTokensRule' function, compute semantic tokens for a Haskell source file.
--
-- This Rule collects information from various sources, including:
--
-- Imported name token type from Rule 'GetDocMap'
-- Local names token type from 'hieAst'
-- Name locations from 'hieAst'
-- Visible names from 'tmrRenamed'

--
-- It then combines this information to compute the semantic tokens for the file.
getSemanticTokensRule :: Recorder (WithPriority SemanticLog) -> Rules ()
getSemanticTokensRule recorder =
  define (cmapWithPrio LogShake recorder) $ \GetSemanticTokens nfp -> handleError recorder $ do
    (HAR {..}) <- lift $ use_ GetHieAst nfp
    (DKMap {getTyThingMap}, _) <- lift $ useWithStale_ GetDocMap nfp
    ast <- handleMaybe (LogNoAST $ show nfp) $ getAsts hieAst M.!? (HiePath . mkFastString . fromNormalizedFilePath) nfp
    virtualFile <- handleMaybeM LogNoVF $ getVirtualFile nfp
    let hsFinder = idSemantic getTyThingMap (hieKindFunMasksKind hieKind) refMap
    return $ computeRangeHsSemanticTokenTypeList hsFinder virtualFile ast


-- taken from /haskell-language-server/plugins/hls-code-range-plugin/src/Ide/Plugin/CodeRange/Rules.hs

-- | Handle error in 'Action'. Returns an 'IdeResult' with no value and no diagnostics on error. (but writes log)
handleError :: Recorder (WithPriority msg) -> ExceptT msg Action a -> Action (IdeResult a)
handleError recorder action' = do
  valueEither <- runExceptT action'
  case valueEither of
    Left msg -> do
      logWith recorder Warning msg
      pure $ toIdeResult (Left [])
    Right value -> pure $ toIdeResult (Right value)

-----------------------
-- helper functions
-----------------------

getAndIncreaseSemanticTokensId :: Action Text
getAndIncreaseSemanticTokensId = do
  ShakeExtras{semanticTokensId} <- getShakeExtras
  liftIO $ atomically $ do
    i <- readTVar semanticTokensId
    modifyTVar' semanticTokensId (+1)
    return $ T.pack $ show i

getPreviousSemanticTokens :: NormalizedUri -> Action (Maybe SemanticTokens)
getPreviousSemanticTokens uri = getShakeExtras >>= liftIO . atomically . STM.lookup uri . semanticTokensCache

setSemanticTokens :: NormalizedUri -> SemanticTokens -> Action ()
setSemanticTokens uri tokens = getShakeExtras >>= liftIO . atomically . STM.insert tokens uri . semanticTokensCache
