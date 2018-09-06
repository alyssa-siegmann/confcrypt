module ConfCrypt.Encryption (

    -- | Working with RSA keys
    KeyProjection,
    project,

    -- | Working with values
    Encrypted,
    renderEncrypted,
    MonadEncrypt,
    encryptValue,
    MonadDecrypt,
    decryptValue,

    -- | Utilities
    loadRSAKey,

    -- | Exported for Testing
    unpackPrivateRSAKey
    ) where

import ConfCrypt.Types

import Control.Monad.Trans (lift, liftIO, MonadIO)
import Control.Monad.Trans.Class (MonadTrans)
import Control.Monad.Except (MonadError, throwError, Except, ExceptT)
import Crypto.PubKey.OpenSsh (OpenSshPublicKey(..), OpenSshPrivateKey(..), decodePublic, decodePrivate)
import qualified Crypto.PubKey.RSA.Types as RSA
import Crypto.Types.PubKey.RSA (PrivateKey(..), PublicKey(..))
import Crypto.PubKey.RSA.PKCS15 (encrypt, decrypt)
import Crypto.Random.Types (MonadRandom, getRandomBytes)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Base64 as B64
import Data.Text as T
import Data.Text.Encoding as T

-- | This class provides the ability to extract specific parts of a keypair from a given RSA 'KeyPair'
class KeyProjection key where
    project :: RSA.KeyPair -> key

instance KeyProjection RSA.PublicKey where
    project = RSA.toPublicKey

instance KeyProjection RSA.PrivateKey where
    project = RSA.toPrivateKey

-- | Given a file on disk that contains the textual representation of an RSA private key (as generated by openssh or ssh-keygen),
-- extract the key from the file and project it into the type of key required.
loadRSAKey :: (MonadIO m, Monad m, MonadError ConfCryptError m, KeyProjection key) =>
    FilePath
    -> m key
loadRSAKey privateKey = do
    prvBytes <- liftIO $ BS.readFile privateKey
    project <$> unpackPrivateRSAKey prvBytes

-- | A private function to actually unpack the RSA key. Only used for testing
unpackPrivateRSAKey :: (MonadError ConfCryptError m) =>
    BS.ByteString
    -> m  RSA.KeyPair
unpackPrivateRSAKey rawPrivateKey =
    case decodePrivate rawPrivateKey of
        Left errMsg -> throwError . KeyUnpackingError $ T.pack errMsg
        Right (OpenSshPrivateKeyDsa _ _ ) -> throwError NonRSAKey
        Right (OpenSshPrivateKeyRsa key ) -> pure $ toKeyPair key
    where
    -- The joys of a needlessly fragmented library ecosystem...
        cryptonitePub key = RSA.PublicKey {
            RSA.public_size = public_size key,
            RSA.public_n = public_n key,
            RSA.public_e = public_e key
            }
        toKeyPair key = RSA.KeyPair $ RSA.PrivateKey {
            RSA.private_pub = cryptonitePub $ private_pub key,
            RSA.private_d = private_d key,
            RSA.private_p = private_p key,
            RSA.private_q = private_q key,
            RSA.private_dP = private_dP key,
            RSA.private_dQ = private_dQ key,
            RSA.private_qinv = private_qinv key
            }

-- TODO use this type in lieu of raw text
newtype Encrypted = Encrypted T.Text
    deriving (Eq, Show)

renderEncrypted :: Encrypted -> T.Text
renderEncrypted (Encrypted encText) = undefined

toEncrypted :: T.Text -> Encrypted
toEncrypted = Encrypted

-- | Decrypts an encrypted block of text
class (Monad m, MonadError ConfCryptError m) => MonadDecrypt m k where
    decryptValue :: k -> T.Text -> m T.Text

instance MonadDecrypt (Except ConfCryptError) RSA.PrivateKey where
    decryptValue _ "" = pure ""
    decryptValue privateKey encryptedValue =
        either (throwError . DecryptionError)
            (pure . T.decodeUtf8) $
            decrypt Nothing privateKey (B64.decodeLenient . BSC.pack $ T.unpack encryptedValue)

class (Monad m, MonadRandom m) => MonadEncrypt m k where
    encryptValue :: k -> T.Text -> m (Either ConfCryptError T.Text)

instance (Monad m, MonadRandom m) => MonadEncrypt m RSA.PublicKey where
    encryptValue _ "" = pure $ Right ""
    encryptValue publicKey nakedValue = do
        res <- encrypt publicKey bytes
        pure $ either (Left . EncryptionError)
               (Right . T.pack . BSC.unpack . B64.encode)
               res
        where
            bytes = T.encodeUtf8 nakedValue

instance (MonadRandom m, MonadTrans n, Monad (n m),Functor (n m) ) => MonadRandom (n m) where
    getRandomBytes = lift . getRandomBytes
