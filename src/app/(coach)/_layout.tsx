import { Stack } from 'expo-router';

export default function CoachLayout() {
  return (
    <Stack
      screenOptions={{
        headerStyle: { backgroundColor: '#131A22' },
        headerTintColor: '#E8EDF2',
        contentStyle: { backgroundColor: '#0B0F14' },
      }}
    >
      <Stack.Screen name="my-athletes" options={{ title: 'My athletes' }} />
      <Stack.Screen name="skills/verify" options={{ title: 'Skill verification' }} />
    </Stack>
  );
}
