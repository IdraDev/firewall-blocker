import type { FBApi } from "../electron/preload";

declare global {
  interface Window {
    fb: FBApi;
  }
}

export {};
