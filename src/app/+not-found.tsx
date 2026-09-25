import { Stack, useRouter } from 'expo-router';
import { Text, View } from 'react-native';

import { Button, Heading, Screen } from '@/components/ui';

export default function NotFoundScreen() {
  const router = useRouter();
  return (
    <>
      <Stack.Screen options={{ title: 'Not found', headerShown: false }} />
      <Screen>
        <View className="flex-1 justify-center">
          <Heading subtitle="The page you opened doesn't exist or has moved.">Page not found</Heading>
          <Text className="mb-6 text-ink-muted">Check the link, or head back to BaCalSys.</Text>
          {/* "/" resolves to Home, login or the approval gate depending on who is signed in. */}
          <Button label="Go to BaCalSys" onPress={() => router.replace('/')} />
        </View>
      </Screen>
    </>
  );
}
