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
      <Stack.Screen name="exercises/index" options={{ headerShown: true, title: 'Exercise library' }} />
      <Stack.Screen name="workouts/index" options={{ headerShown: true, title: 'Routines' }} />
      <Stack.Screen name="workouts/builder" options={{ headerShown: true, title: 'New routine' }} />
      <Stack.Screen name="workouts/[id]" options={{ headerShown: true, title: 'Routine' }} />
      <Stack.Screen name="workouts/version" options={{ headerShown: true, title: 'New version' }} />
    </Stack>
  );
}
