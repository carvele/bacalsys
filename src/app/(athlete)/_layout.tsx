import { Stack } from 'expo-router';

export default function AthleteLayout() {
  return (
    <Stack
      screenOptions={{
        headerShown: false,
        headerStyle: { backgroundColor: '#131A22' },
        headerTintColor: '#E8EDF2',
        contentStyle: { backgroundColor: '#0B0F14' },
      }}
    >
      <Stack.Screen name="index" />
      <Stack.Screen name="history/index" options={{ headerShown: true, title: 'Training history' }} />
      <Stack.Screen name="history/[id]" options={{ headerShown: true, title: 'Session' }} />
      <Stack.Screen name="skills/index" options={{ headerShown: true, title: 'Skills' }} />
      <Stack.Screen name="skills/[id]" options={{ headerShown: true, title: 'Skill' }} />
      <Stack.Screen name="exercises/index" options={{ headerShown: true, title: 'Exercise library' }} />
      <Stack.Screen name="workouts/index" options={{ headerShown: true, title: 'Routines' }} />
      <Stack.Screen name="workouts/builder" options={{ headerShown: true, title: 'New routine' }} />
      <Stack.Screen name="workouts/[id]" options={{ headerShown: true, title: 'Routine' }} />
      <Stack.Screen name="workouts/version" options={{ headerShown: true, title: 'New version' }} />
      <Stack.Screen name="workout/active" options={{ headerShown: true, title: 'Workout', gestureEnabled: false }} />
      <Stack.Screen name="workout/summary" options={{ headerShown: true, title: 'Summary', gestureEnabled: false }} />
    </Stack>
  );
}
