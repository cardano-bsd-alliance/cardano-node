module Cardano.Tracer.Environment
  ( TracerEnv (..)
  ) where

import           Control.Concurrent.Extra (Lock)

import           Cardano.Tracer.Configuration
import           Cardano.Tracer.Handlers.RTView.Notifications.Types
import           Cardano.Tracer.Handlers.RTView.State.Historical
import           Cardano.Tracer.Handlers.RTView.State.TraceObjects
import           Cardano.Tracer.Types

-- | Environment for all functions.
data TracerEnv = TracerEnv
  { teConfig            :: !TracerConfig
  , teConnectedNodes    :: !ConnectedNodes
  , teAcceptedMetrics   :: !AcceptedMetrics
  , teSavedTO           :: !SavedTraceObjects
  , teBlockchainHistory :: !BlockchainHistory
  , teResourcesHistory  :: !ResourcesHistory
  , teTxHistory         :: !TransactionsHistory
  , teCurrentLogLock    :: !Lock
  , teCurrentDPLock     :: !Lock
  , teEventsQueues      :: !EventsQueues
  , teDPRequestors      :: !DataPointRequestors
  , teProtocolsBrake    :: !ProtocolsBrake
  }
