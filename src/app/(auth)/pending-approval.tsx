import { View } from 'react-native';

import { Button, Card, Heading, Notice, Screen } from '@/components/ui';
import { useAuth } from '@/features/auth/use-auth';
import { describeError } from '@/lib/errors';

const copy = {
  pending_approval: {
    title: 'Awaiting approval',
    body: 'Thanks for registering. A club officer will review your application. This screen updates automatically once you are approved.',
  },
  suspended: {
    title: 'Membership suspended',
    body: 'Your membership is currently suspended. Contact a club officer for details.',
  },
  rejected: {
    title: 'Application not approved',
    body: 'Your application was not approved. Contact a club officer if you think this is a mistake.',
  },
} as const;

/** Every signed-in, non-active user is held here (DoD #12). */
export default function PendingApprovalScreen() {
  const { route, profile, email, error, isRefreshing, refresh, signOut } = useAuth();
  const status = profile?.status;
  const content = status && status !== 'active' ? copy[status] : null;

  return (
    <Screen>
      <View className="flex-1 justify-center">
        <Heading subtitle={email ?? undefined}>{content?.title ?? 'Checking your membership'}</Heading>
        <View className="gap-4">
          {route === 'error' ? (
            <Notice tone="danger">{describeError(error)}</Notice>
          ) : content ? (
            <Card>
              <Notice tone={status === 'pending_approval' ? 'warning' : 'danger'}>{content.body}</Notice>
            </Card>
          ) : null}
          <Button label="Check status" variant="secondary" onPress={refresh} loading={isRefreshing} />
          <Button label="Sign out" variant="ghost" onPress={signOut} />
        </View>
      </View>
    </Screen>
  );
}
