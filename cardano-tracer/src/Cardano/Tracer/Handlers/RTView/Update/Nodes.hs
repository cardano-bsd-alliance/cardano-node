{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Tracer.Handlers.RTView.Update.Nodes
  ( addColumnsForConnected
  , addDatasetsForConnected
  , checkNoNodesState
  , updateNodesUI
  , updateNodesUptime
  ) where

import           Control.Concurrent.STM (atomically)
import           Control.Concurrent.STM.TVar
import           Control.Monad (forM_, unless, when)
import           Control.Monad.Extra (whenJust)
import           Data.List (find)
import           Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as M
import           Data.Maybe (catMaybes, fromMaybe)
import           Data.Set (Set, (\\))
import qualified Data.Set as S
import qualified Data.Text as T
import           Data.Text.Read (double)
import           Data.Time.Calendar (diffDays)
import           Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, utctDay)
import           Data.Time.Clock.System (getSystemTime, systemToUTCTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           Data.Word (Word64)
import qualified Graphics.UI.Threepenny as UI
import           Graphics.UI.Threepenny.Core
import           Text.Read (readMaybe)

import           Cardano.Tracer.Configuration
import           Cardano.Tracer.Environment
import           Cardano.Tracer.Handlers.Metrics.Utils
import           Cardano.Tracer.Handlers.RTView.State.Displayed
import           Cardano.Tracer.Handlers.RTView.State.EraSettings
import           Cardano.Tracer.Handlers.RTView.State.Errors
import           Cardano.Tracer.Handlers.RTView.State.TraceObjects
import           Cardano.Tracer.Handlers.RTView.UI.Charts
import           Cardano.Tracer.Handlers.RTView.UI.HTML.Node.Column
import           Cardano.Tracer.Handlers.RTView.UI.HTML.NoNodes
import           Cardano.Tracer.Handlers.RTView.UI.Types
import           Cardano.Tracer.Handlers.RTView.UI.Utils
import           Cardano.Tracer.Handlers.RTView.Update.NodeInfo
import           Cardano.Tracer.Handlers.RTView.Update.Utils
import           Cardano.Tracer.Handlers.RTView.Utils
import           Cardano.Tracer.Types

updateNodesUI
  :: TracerEnv
  -> DisplayedElements
  -> ErasSettings
  -> NonEmpty LoggingParams
  -> Colors
  -> DatasetsIndices
  -> Errors
  -> UI.Timer
  -> UI.Timer
  -> UI ()
updateNodesUI tracerEnv@TracerEnv{teConnectedNodes, teAcceptedMetrics, teSavedTO}
              displayedElements nodesEraSettings loggingConfig colors
              datasetIndices nodesErrors updateErrorsTimer noNodesProgressTimer = do
  (connected, displayedEls) <- liftIO . atomically $ (,)
    <$> readTVar teConnectedNodes
    <*> readTVar displayedElements
  -- Check connected/disconnected nodes since previous UI's update.
  let displayed = S.fromList $ M.keys displayedEls
  when (connected /= displayed) $ do
    let disconnected   = displayed \\ connected -- In 'displayed' but not in 'connected'.
        newlyConnected = connected \\ displayed -- In 'connected' but not in 'displayed'.
    deleteColumnsForDisconnected connected disconnected
    addColumnsForConnected
      tracerEnv
      newlyConnected
      loggingConfig
      nodesErrors
      updateErrorsTimer
    checkNoNodesState connected noNodesProgressTimer
    askNSetNodeInfo tracerEnv newlyConnected displayedElements
    addDatasetsForConnected tracerEnv newlyConnected colors datasetIndices
    restoreLastHistoryOnCharts tracerEnv datasetIndices newlyConnected
    liftIO $
      updateDisplayedElements displayedElements connected
  setBlockReplayProgress connected teAcceptedMetrics
  setChunkValidationProgress connected teSavedTO
  setLedgerDBProgress connected teSavedTO
  setLeadershipStats connected displayedElements teAcceptedMetrics
  setEraEpochInfo connected displayedElements teAcceptedMetrics nodesEraSettings

addColumnsForConnected
  :: TracerEnv
  -> Set NodeId
  -> NonEmpty LoggingParams
  -> Errors
  -> UI.Timer
  -> UI ()
addColumnsForConnected tracerEnv newlyConnected loggingConfig nodesErrors updateErrorsTimer = do
  unless (S.null newlyConnected) $ do
    window <- askWindow
    findAndShow window "main-table-container"
  forM_ newlyConnected $
    addNodeColumn
      tracerEnv
      loggingConfig
      nodesErrors
      updateErrorsTimer

addDatasetsForConnected
  :: TracerEnv
  -> Set NodeId
  -> Colors
  -> DatasetsIndices
  -> UI ()
addDatasetsForConnected tracerEnv newlyConnected colors datasetIndices = do
  unless (S.null newlyConnected) $ do
    window <- askWindow
    findAndShow window "main-charts-container"
  forM_ newlyConnected $
    addNodeDatasetsToCharts tracerEnv colors datasetIndices

deleteColumnsForDisconnected
  :: Set NodeId
  -> Set NodeId
  -> UI ()
deleteColumnsForDisconnected connected disconnected = do
  window <- askWindow
  forM_ disconnected $ deleteNodeColumn window
  when (S.null connected) $ do
    findAndHide window "main-table-container"
    findAndHide window "main-charts-container"
  -- Please note that we don't remove historical data from charts
  -- for disconnected node. Because the user may want to see the
  -- historical data even for the node that already disconnected.

checkNoNodesState
  :: Set NodeId
  -> UI.Timer
  -> UI ()
checkNoNodesState connected noNodesProgressTimer = do
  window <- askWindow
  if S.null connected
    then showNoNodes window noNodesProgressTimer
    else hideNoNodes window noNodesProgressTimer

updateNodesUptime
  :: TracerEnv
  -> DisplayedElements
  -> UI ()
updateNodesUptime tracerEnv displayedElements = do
  now <- systemToUTCTime <$> liftIO getSystemTime
  displayed <- liftIO $ readTVarIO displayedElements
  elsIdsWithUptimes <- forConnectedUI tracerEnv $ getUptimeForNode now displayed
  setTextValues $ catMaybes elsIdsWithUptimes
 where
   getUptimeForNode now displayed nodeId@(NodeId anId) = do
    let nodeStartElId  = anId <> "__node-start-time"
        nodeUptimeElId = anId <> "__node-uptime"
    case getDisplayedValuePure displayed nodeId nodeStartElId of
       Nothing -> return Nothing
       Just tsRaw ->
         case readMaybe (T.unpack tsRaw) of
           Nothing -> return Nothing
           Just (startTime :: UTCTime) -> do
             let uptimeDiff = now `diffUTCTime` startTime
                 uptime = uptimeDiff `addUTCTime` nullTime
                 uptimeFormatted = formatTime defaultTimeLocale "%X" uptime
                 daysNum = utctDay uptime `diffDays` utctDay nullTime
                 uptimeWithDays = if daysNum > 0
                                    -- Show days only if 'uptime' > 23:59:59.
                                    then show daysNum <> "d " <> uptimeFormatted
                                    else uptimeFormatted
             return $ Just (nodeUptimeElId, T.pack uptimeWithDays)

setBlockReplayProgress
  :: Set NodeId
  -> AcceptedMetrics
  -> UI ()
setBlockReplayProgress connected acceptedMetrics = do
  allMetrics <- liftIO $ readTVarIO acceptedMetrics
  forM_ connected $ \nodeId ->
    whenJust (M.lookup nodeId allMetrics) $ \(ekgStore, _) -> do
      metrics <- liftIO $ getListOfMetrics ekgStore
      whenJust (lookup "ChainDB.BlockReplayProgress" metrics) $ \metricValue ->
        updateBlockReplayProgress nodeId metricValue
 where
  updateBlockReplayProgress (NodeId anId) mValue =
    case double mValue of
      Left _ -> return ()
      Right (progressPct, _) -> do
        let nodeBlockReplayElId = anId <> "__node-block-replay"
            progressPctS = T.pack $ show progressPct
        if "100" `T.isInfixOf` progressPctS
          then setTextAndClasses nodeBlockReplayElId "100&nbsp;%" "rt-view-percent-done"
          else setTextValue nodeBlockReplayElId $ progressPctS <> "&nbsp;%"

setChunkValidationProgress
  :: Set NodeId
  -> SavedTraceObjects
  -> UI ()
setChunkValidationProgress connected savedTO = do
  savedTraceObjects <- liftIO $ readTVarIO savedTO
  forM_ connected $ \nodeId@(NodeId anId) ->
    whenJust (M.lookup nodeId savedTraceObjects) $ \savedTOForNode -> do
      let nodeChunkValidationElId = anId <> "__node-chunk-validation"
      forM_ (M.toList savedTOForNode) $ \(namespace, (trObValue, _, _)) ->
        case namespace of
          "ChainDB.ImmutableDBEvent.ChunkValidation.ValidatedChunk" ->
            -- In this case we don't need to check if the value differs from displayed one,
            -- because this 'TraceObject' is forwarded only with new values, and after 100%
            -- the node doesn't forward it anymore.
            --
            -- Example: "Validated chunk no. 2262 out of 2423. Progress: 93.36%"
            case T.words trObValue of
              [_, _, _, current, _, _, from, _, progressPct] ->
                setTextValue nodeChunkValidationElId $
                             T.init progressPct <> "&nbsp;%: no. " <> current <> " from " <> T.init from
              _ -> return ()
          "ChainDB.ImmutableDBEvent.ValidatedLastLocation" ->
            setTextAndClasses nodeChunkValidationElId "100&nbsp;%" "rt-view-percent-done"
          _ -> return ()

setLedgerDBProgress
  :: Set NodeId
  -> SavedTraceObjects
  -> UI ()
setLedgerDBProgress connected savedTO = do
  savedTraceObjects <- liftIO $ readTVarIO savedTO
  forM_ connected $ \nodeId@(NodeId anId) ->
    whenJust (M.lookup nodeId savedTraceObjects) $ \savedTOForNode -> do
      let nodeLedgerDBUpdateElId = anId <> "__node-update-ledger-db"
      forM_ (M.toList savedTOForNode) $ \(namespace, (trObValue, _, _)) ->
        case namespace of
          "ChainDB.InitChainSelEvent.UpdateLedgerDb" ->
            -- In this case we don't need to check if the value differs from displayed one,
            -- because this 'TraceObject' is forwarded only with new values, and after 100%
            -- the node doesn't forward it anymore.
            --
            -- Example: "Pushing ledger state for block b1e6...fc5a at slot 54495204. Progress: 3.66%"
            case T.words trObValue of
              [_, _, _, _, _, _, _, _, _, _, progressPct] -> do
                if "100" `T.isInfixOf` progressPct
                  then setTextAndClasses nodeLedgerDBUpdateElId "100&nbsp;%" "rt-view-percent-done"
                  else setTextValue nodeLedgerDBUpdateElId $ T.init progressPct <> "&nbsp;%"
              _ -> return ()
          _ -> return ()

setLeadershipStats
  :: Set NodeId
  -> DisplayedElements
  -> AcceptedMetrics
  -> UI ()
setLeadershipStats connected displayed acceptedMetrics = do
  allMetrics <- liftIO $ readTVarIO acceptedMetrics
  forM_ connected $ \nodeId@(NodeId anId) ->
    whenJust (M.lookup nodeId allMetrics) $ \(ekgStore, _) -> do
      metrics <- liftIO $ getListOfMetrics ekgStore
      forM_ metrics $ \(mName, mValue) ->
        case mName of
          -- How many times this node was a leader.
          "Forge.NodeIsLeaderNum"    -> setDisplayedValue nodeId displayed (anId <> "__node-leadership") mValue
          -- How many blocks were forged by this node.
          "Forge.BlocksForgedNum"    -> setDisplayedValue nodeId displayed (anId <> "__node-forged-blocks") mValue
          -- How many times this node could not forge.
          "Forge.NodeCannotForgeNum" -> setDisplayedValue nodeId displayed (anId <> "__node-cannot-forge") mValue
          -- How many slots were missed in this node.
          "Forge.SlotsMissed"        -> setDisplayedValue nodeId displayed (anId <> "__node-missed-slots") mValue
          _ -> return ()

setEraEpochInfo
  :: Set NodeId
  -> DisplayedElements
  -> AcceptedMetrics
  -> ErasSettings
  -> UI ()
setEraEpochInfo connected displayed acceptedMetrics nodesEraSettings = do
  allSettings <- liftIO $ readTVarIO nodesEraSettings
  allMetrics <- liftIO $ readTVarIO acceptedMetrics
  forM_ connected $ \nodeId@(NodeId anId) -> do
    epochS <-
      case M.lookup nodeId allMetrics of
        Just (ekgStore, _) -> do
          metrics <- liftIO $ getListOfMetrics ekgStore
          return $ fromMaybe "" $ lookup "ChainDB.Epoch" metrics
        Nothing -> return ""
    unless (T.null epochS) $
      setDisplayedValue nodeId displayed (anId <> "__node-epoch-num") epochS

    whenJust (M.lookup nodeId allSettings) $ \settings -> do
      setDisplayedValue nodeId displayed (anId <> "__node-era") $ esEra settings
      updateEpochInfo settings nodeId epochS
 where
  updateEpochInfo settings (NodeId anId) epochS =
    unless (T.null epochS) $ do
      let epochNum = readInt epochS 0
      case getEndOfCurrentEpoch settings epochNum of
        Nothing -> return ()
        Just (_start, end) -> do
          setTextValue (anId <> "__node-epoch-end") $
                       T.pack $ formatTime defaultTimeLocale "%D %T" end
          {-
          let elapsedSecondsFromEpochStart = nesSlotLengthInS settings * slotInEpoch
              diffFromEndToStart = end `diffUTCTime` start
              elapsed = secondsToNominalDiffTime (fromIntegral elapsedSecondsFromEpochStart)
              diffFromNowToEnd = diffFromEndToStart - elapsed
              timeLeft = diffFromNowToEnd `addUTCTime` nullTime
              timeLeftF = T.pack $ formatTime defaultTimeLocale "%d:%H:%M:%S" timeLeft
          setTextValue (anId <> "__node-epoch-end") timeLeftF
          -}

  getEndOfCurrentEpoch EraSettings{esEra, esSlotLengthInS, esEpochLength} currentEpoch =
    case lookup esEra epochsInfo of
      Nothing ->
        -- So, there is no such an era. The possible reason: this is "too new" era
        -- (not officially forked yet). Try to find corresponding epoch directly.
        case find (\(_, (_, firstEpoch)) -> currentEpoch >= firstEpoch) epochsInfo of
          Nothing -> Nothing
          Just (_, (epochStart, firstEpoch)) -> getEpochDates epochStart firstEpoch
      Just (epochStart, firstEpoch) -> getEpochDates epochStart firstEpoch
   where
    getEpochDates startDate firstEpoch =
      let elapsedEpochsInEra = currentEpoch - firstEpoch
          epochLengthInS = esSlotLengthInS * esEpochLength
          secondsFromEpochStartToEpoch = epochLengthInS * elapsedEpochsInEra
          !dateOfEpochStart = startDate + fromIntegral secondsFromEpochStartToEpoch
          !dateOfEpochEnd = dateOfEpochStart + fromIntegral epochLengthInS
      in Just (s2utc dateOfEpochStart, s2utc dateOfEpochEnd)

type EraName         = T.Text
type FirstEpochInEra = Int
type EraStartPOSIX   = Word64

-- It is taken from 'cardano-ledger' wiki topic "First-Block-of-Each-Era".
epochsInfo :: [(EraName, (EraStartPOSIX, FirstEpochInEra))]
epochsInfo =
  [ ("Shelley", (1596073491, 208)) -- 07/30/2020 1:44:51 AM GMT
  , ("Allegra", (1608169491, 236)) -- 12/17/2020 1:44:51 AM GMT
  , ("Mary",    (1614649491, 251)) -- 03/02/2021 1:44:51 AM GMT
  , ("Alonzo",  (1634953491, 298)) -- 10/23/2021 1:44:51 AM GMT, start of new protocol.
  ]
