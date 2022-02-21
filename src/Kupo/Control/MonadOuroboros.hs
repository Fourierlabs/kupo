--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE TypeApplications #-}

module Kupo.Control.MonadOuroboros
    ( MonadOuroboros (..)
    , NetworkMagic (..)
    , EpochSlots (..)
    , NodeToClientVersion (..)
    ) where

import Kupo.Prelude

import Cardano.Chain.Slotting
    ( EpochSlots (..) )
import Cardano.Ledger.Crypto
    ( StandardCrypto )
import Control.Tracer
    ( nullTracer )
import Data.Map.Strict
    ( (!) )
import Ouroboros.Consensus.Byron.Ledger.Config
    ( CodecConfig (..) )
import Ouroboros.Consensus.Cardano
    ( CardanoBlock )
import Ouroboros.Consensus.Cardano.Block
    ( CodecConfig (..) )
import Ouroboros.Consensus.Network.NodeToClient
    ( ClientCodecs, Codecs' (..), clientCodecs )
import Ouroboros.Consensus.Node.NetworkProtocolVersion
    ( SupportedNetworkProtocolVersion (..) )
import Ouroboros.Consensus.Shelley.Ledger.Config
    ( CodecConfig (..) )
import Ouroboros.Network.Block
    ( Point (..), Tip (..) )
import Ouroboros.Network.Driver.Simple
    ( runPipelinedPeer )
import Ouroboros.Network.Magic
    ( NetworkMagic (..) )
import Ouroboros.Network.Mux
    ( MiniProtocol (..)
    , MiniProtocolLimits (..)
    , MiniProtocolNum (..)
    , MuxPeer (..)
    , OuroborosApplication (..)
    , RunMiniProtocol (..)
    )
import Ouroboros.Network.NodeToClient
    ( NetworkConnectTracers (..)
    , NodeToClientVersion (..)
    , NodeToClientVersionData (..)
    , connectTo
    , localSnocket
    , withIOManager
    )
import Ouroboros.Network.Protocol.ChainSync.ClientPipelined
    ( ChainSyncClientPipelined (..), chainSyncClientPeerPipelined )
import Ouroboros.Network.Protocol.Handshake.Version
    ( combineVersions, simpleSingletonVersions )

class MonadOuroboros (m :: Type -> Type) where
    type Block m :: Type
    withChainSyncServer
        :: [NodeToClientVersion]
        -> NetworkMagic
        -> EpochSlots
        -> FilePath
        -> ChainSyncClientPipelined (Block m) (Point (Block m)) (Tip (Block m)) IO ()
        -> m ()

instance MonadOuroboros IO where
    type Block IO = CardanoBlock StandardCrypto
    withChainSyncServer wantedVersions networkMagic slotsPerEpoch socket client =
        withIOManager $ \iocp -> do
            connectTo (localSnocket iocp) tracers versions socket
      where
        tracers = NetworkConnectTracers
            { nctMuxTracer = nullTracer
            , nctHandshakeTracer = nullTracer
            }

        versions = combineVersions
            [ simpleSingletonVersions v vData (mkOuroborosApplication v)
            | v <- wantedVersions
            ]
          where
            vData  = NodeToClientVersionData networkMagic

        mkOuroborosApplication version =
            OuroborosApplication $ \_connectionId _controlMessageSTM ->
                [ MiniProtocol
                    { miniProtocolNum =
                        MiniProtocolNum 5
                    , miniProtocolLimits =
                        MiniProtocolLimits (fromIntegral $ maxBound @Word32)
                    , miniProtocolRun =
                        InitiatorProtocolOnly $ MuxPeerRaw $ \channel ->
                            let
                                peer = chainSyncClientPeerPipelined client
                                codec = cChainSyncCodec (codecs slotsPerEpoch version)
                                tr = nullTracer
                             in
                                runPipelinedPeer tr codec channel peer
                    }
                ]

instance MonadOuroboros (ReaderT r IO) where
    type Block (ReaderT r IO) = Block IO
    withChainSyncServer wantedVersions networkMagic slotsPerEpoch socket =
        lift . withChainSyncServer wantedVersions networkMagic slotsPerEpoch socket

codecs
    :: EpochSlots
    -> NodeToClientVersion
    -> ClientCodecs (Block IO) IO
codecs epochSlots nodeToClientV =
    clientCodecs cfg (supportedVersions ! nodeToClientV) nodeToClientV
  where
    supportedVersions =
        supportedNodeToClientVersions (Proxy @(Block IO))
    cfg =
        CardanoCodecConfig byron shelley allegra mary alonzo
      where
        byron   = ByronCodecConfig epochSlots
        shelley = ShelleyCodecConfig
        allegra = ShelleyCodecConfig
        mary    = ShelleyCodecConfig
        alonzo  = ShelleyCodecConfig