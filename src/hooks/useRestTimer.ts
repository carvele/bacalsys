import { useAudioPlayer } from 'expo-audio';
import * as Haptics from 'expo-haptics';
import * as Notifications from 'expo-notifications';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, Platform } from 'react-native';

/**
 * Sprint 4 · Task 4.11 — drift-free absolute rest timer.
 *
 * Rest is tracked as an absolute wall-clock `restEndsAt` epoch, never a
 * decrementing counter, so returning from the background or a locked screen
 * recalculates the true remaining time instead of drifting. Foreground alert
 * is a chime (expo-audio) + a success haptic; because JS timers are
 * suspended while backgrounded/locked, the same expiry is ALSO scheduled as a
 * native date-trigger notification (expo-notifications), cancelled on
 * foreground return, skip or manual dismiss.
 */

// Foreground: the app already shows its own chime/haptic, but a background ->
// foreground race can still deliver the OS notification after the app is
// frontmost again; suppress its banner/list entry in that case, never its sound.
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldPlaySound: true,
    shouldSetBadge: false,
    shouldShowBanner: AppState.currentState !== 'active',
    shouldShowList: AppState.currentState !== 'active',
  }),
});

const CHIME_ASSET = require('../../assets/audio/rest-complete.wav') as number;

export interface UseRestTimerResult {
  isActive: boolean;
  targetSeconds: number;
  remainingSeconds: number;
  /** Starts (or restarts) the rest timer for the given duration. */
  start: (seconds: number) => Promise<void>;
  /** Ends the rest immediately and fires the completion chime/haptic, as if it had naturally expired. */
  skip: () => void;
  /** Silently cancels the rest without firing completion (e.g. the athlete backed out). */
  cancel: () => void;
}

export function useRestTimer(): UseRestTimerResult {
  const player = useAudioPlayer(CHIME_ASSET);
  const [restEndsAt, setRestEndsAt] = useState<number | null>(null);
  const [targetSeconds, setTargetSeconds] = useState(0);
  const [remainingSeconds, setRemainingSeconds] = useState(0);
  const notificationIdRef = useRef<string | null>(null);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const clearTick = useCallback(() => {
    if (intervalRef.current !== null) {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
  }, []);

  const cancelNotification = useCallback(async () => {
    const id = notificationIdRef.current;
    notificationIdRef.current = null;
    if (id) await Notifications.cancelScheduledNotificationAsync(id).catch(() => {});
  }, []);

  const finish = useCallback(
    (playCue: boolean) => {
      clearTick();
      setRestEndsAt(null);
      setRemainingSeconds(0);
      void cancelNotification();
      if (playCue && AppState.currentState === 'active') {
        player.play();
        void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
      }
    },
    [cancelNotification, clearTick, player],
  );

  const tick = useCallback(
    (endsAt: number) => {
      const remaining = Math.max(0, Math.ceil((endsAt - Date.now()) / 1000));
      setRemainingSeconds(remaining);
      if (remaining <= 0) finish(true);
    },
    [finish],
  );

  const start = useCallback(
    async (seconds: number) => {
      await cancelNotification();
      clearTick();
      const endsAt = Date.now() + Math.max(0, seconds) * 1000;
      setTargetSeconds(seconds);
      setRestEndsAt(endsAt);
      setRemainingSeconds(seconds);

      if (Platform.OS !== 'web') {
        const { status } = await Notifications.getPermissionsAsync();
        if (status !== 'granted') await Notifications.requestPermissionsAsync().catch(() => null);
        try {
          notificationIdRef.current = await Notifications.scheduleNotificationAsync({
            content: { title: 'Rest complete', body: 'Time for your next set!', sound: true },
            trigger: { type: Notifications.SchedulableTriggerInputTypes.DATE, date: new Date(endsAt) },
          });
        } catch {
          notificationIdRef.current = null;
        }
      }

      intervalRef.current = setInterval(() => tick(endsAt), 250);
    },
    [cancelNotification, clearTick, tick],
  );

  const skip = useCallback(() => finish(true), [finish]);
  const cancel = useCallback(() => finish(false), [finish]);

  // Drift-free recovery: recompute the instant the app returns to the foreground.
  useEffect(() => {
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active' && restEndsAt !== null) tick(restEndsAt);
    });
    return () => subscription.remove();
  }, [restEndsAt, tick]);

  useEffect(
    () => () => {
      clearTick();
      void cancelNotification();
    },
    [clearTick, cancelNotification],
  );

  return { isActive: restEndsAt !== null, targetSeconds, remainingSeconds, start, skip, cancel };
}
