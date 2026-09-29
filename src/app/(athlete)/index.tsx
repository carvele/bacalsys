import { useRouter } from 'expo-router';
import { Text, View } from 'react-native';

import { TodaysTrainingCard } from '@/components/TodaysTrainingCard';
import { Button, Card, Heading, Screen } from '@/components/ui';
import { hasPermission } from '@/features/auth/access';
import { useAuth } from '@/features/auth/use-auth';
import { usePendingSkillAttempts } from '@/lib/skills';

/** Task 1.13: Athlete Home, the landing screen for every approved member. */
export default function AthleteHomeScreen() {
  const router = useRouter();
  const { profile, access, email, signOut } = useAuth();
  const firstName = profile?.full_name.split(' ')[0] || 'Athlete';
  const positions = access?.positions ?? [];
  const canReviewMembers = hasPermission(access, 'members:approve');
  const canAssignCoaches = hasPermission(access, 'coaches:assign');
  const canReviewExercises = hasPermission(access, 'exercises:approve');
  const canVerifySkills = hasPermission(access, 'skills:verify');
  const isCoach = positions.includes('Coach');
  const hasOfficerTools = canReviewMembers || canAssignCoaches || canReviewExercises || canVerifySkills;

  // Sprint 6 · Task 6.15: pending count for the verification queue badge.
  const pendingSkills = usePendingSkillAttempts(canVerifySkills);
  const pendingCount = pendingSkills.data?.length ?? 0;

  return (
    <Screen>
      <Heading subtitle={email ?? undefined}>{`Hi, ${firstName}`}</Heading>

      <View className="gap-4">
        <Card className="gap-3">
          <Text className="text-sm font-medium uppercase tracking-wide text-ink-muted">Your standing</Text>
          <View className="flex-row flex-wrap gap-2">
            {positions.map((p) => (
              <View key={p} className="rounded-full bg-brand-soft px-3 py-1">
                <Text className="text-sm font-semibold text-brand">{p}</Text>
              </View>
            ))}
            {access?.isSystemAdmin ? (
              <View className="rounded-full bg-surface-sunken px-3 py-1">
                <Text className="text-sm font-semibold text-ink">System Administrator</Text>
              </View>
            ) : null}
          </View>
        </Card>

        <TodaysTrainingCard />

        <Card className="gap-3">
          <Text className="text-title text-ink">Exercise library</Text>
          <Text className="text-ink-muted">Browse official movements and create your own custom exercises.</Text>
          <Button label="Open exercise library" variant="secondary" onPress={() => router.push('/exercises')} />
        </Card>

        <Card className="gap-3">
          <Text className="text-title text-ink">Workout routines</Text>
          <Text className="text-ink-muted">Build set-by-set routines and browse your club&apos;s templates.</Text>
          <Button label="Open routines" variant="secondary" onPress={() => router.push('/workouts')} />
        </Card>

        <Card className="gap-3">
          <Text className="text-title text-ink">Training history</Text>
          <Text className="text-ink-muted">Review past sessions and your 30-day adherence.</Text>
          <Button label="Open training history" variant="secondary" onPress={() => router.push('/history')} />
        </Card>

        <Card className="gap-3">
          <Text className="text-title text-ink">Calisthenics skills</Text>
          <Text className="text-ink-muted">Track your progress through the club&apos;s skill trees.</Text>
          <Button label="Open skills" variant="secondary" onPress={() => router.push('/skills')} />
        </Card>

        {isCoach ? (
          <Card className="gap-3">
            <Text className="text-title text-ink">Coaching</Text>
            <Button label="My athletes" variant="secondary" onPress={() => router.push('/my-athletes')} />
          </Card>
        ) : null}

        {hasOfficerTools ? (
          <Card className="gap-3">
            <Text className="text-title text-ink">Officer tools</Text>
            {canReviewMembers ? (
              <Button label="Review member applications" onPress={() => router.push('/member-approvals')} />
            ) : null}
            {canAssignCoaches ? (
              <Button label="Assign coaches" onPress={() => router.push('/coach-assignment')} />
            ) : null}
            {canReviewExercises ? (
              <Button label="Review custom exercises" onPress={() => router.push('/exercise-approvals')} />
            ) : null}
            {canVerifySkills ? (
              <View className="flex-row items-center gap-2">
                <View className="flex-1">
                  <Button label="Skill verification queue" onPress={() => router.push('/skills/verify')} />
                </View>
                {pendingCount > 0 ? (
                  <View accessibilityLabel={`${pendingCount} pending`} className="min-w-6 items-center rounded-full bg-danger px-2 py-1">
                    <Text className="text-xs font-bold text-white">{pendingCount}</Text>
                  </View>
                ) : null}
              </View>
            ) : null}
          </Card>
        ) : null}

        <Button label="Sign out" variant="ghost" onPress={signOut} />
      </View>
    </Screen>
  );
}
