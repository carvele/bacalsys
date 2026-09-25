/** Web: browser localStorage. Guarded so a non-browser JS context never throws. */
const hasLocalStorage = () => {
  try {
    return typeof window !== 'undefined' && window.localStorage != null;
  } catch {
    return false;
  }
};

export const authStorage = {
  async getItem(key: string): Promise<string | null> {
    return hasLocalStorage() ? window.localStorage.getItem(key) : null;
  },
  async setItem(key: string, value: string): Promise<void> {
    if (hasLocalStorage()) window.localStorage.setItem(key, value);
  },
  async removeItem(key: string): Promise<void> {
    if (hasLocalStorage()) window.localStorage.removeItem(key);
  },
};
