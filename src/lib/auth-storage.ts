import * as SecureStore from 'expo-secure-store';

import { createChunkedStorage } from './chunked-storage';

/** Native (iOS/Android): Keychain / Keystore-backed session storage. */
export const authStorage = createChunkedStorage({
  getItem: (key) => SecureStore.getItemAsync(key),
  setItem: (key, value) => SecureStore.setItemAsync(key, value),
  removeItem: (key) => SecureStore.deleteItemAsync(key),
});
