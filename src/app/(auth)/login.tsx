import { Link } from 'expo-router';
import { useRef, useState } from 'react';
import { Text, View, type TextInput } from 'react-native';

import { Button, Heading, Notice, Screen, TextField } from '@/components/ui';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

export default function LoginScreen() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const passwordRef = useRef<TextInput>(null);

  const canSubmit = email.trim().length > 0 && password.length > 0;

  async function onSubmit() {
    if (!canSubmit || submitting) return;
    setSubmitting(true);
    setError(null);
    const { error: signInError } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    });
    // On success the auth listener updates the session and the route guard navigates.
    if (signInError) setError(describeError(signInError));
    setSubmitting(false);
  }

  return (
    <Screen>
      <View className="flex-1 justify-center">
        <Heading subtitle="Bataan Calisthenics System">Sign in</Heading>
        <View className="gap-4">
          {error ? <Notice tone="danger">{error}</Notice> : null}
          <TextField
            label="Email"
            value={email}
            onChangeText={setEmail}
            autoCapitalize="none"
            autoComplete="email"
            keyboardType="email-address"
            textContentType="emailAddress"
            returnKeyType="next"
            onSubmitEditing={() => passwordRef.current?.focus()}
          />
          <TextField
            ref={passwordRef}
            label="Password"
            value={password}
            onChangeText={setPassword}
            secureTextEntry
            autoComplete="current-password"
            textContentType="password"
            returnKeyType="go"
            onSubmitEditing={onSubmit}
          />
          <Button label="Sign in" onPress={onSubmit} loading={submitting} disabled={!canSubmit} />
        </View>
        <View className="mt-6 flex-row justify-center gap-1">
          <Text className="text-ink-muted">New to the club?</Text>
          <Link href="/register" className="font-semibold text-brand">
            Create an account
          </Link>
        </View>
      </View>
    </Screen>
  );
}
