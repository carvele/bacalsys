import { Stack } from 'expo-router';

export default function OfficerLayout() {
  return (
    <Stack
      screenOptions={{
        headerStyle: { backgroundColor: '#131A22' },
        headerTintColor: '#E8EDF2',
        contentStyle: { backgroundColor: '#0B0F14' },
      }}
    >
      <Stack.Screen name="member-approvals" options={{ title: 'Member approvals' }} />
      <Stack.Screen name="coach-assignment" options={{ title: 'Assign coaches' }} />
      <Stack.Screen name="exercise-approvals" options={{ title: 'Exercise approvals' }} />
    </Stack>
  );
}
