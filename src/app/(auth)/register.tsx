import { useLocalSearchParams } from 'expo-router';
import { useRef, useState } from 'react';
import { Text, View, type TextInput } from 'react-native';

import { Button, Heading, Notice, Screen, TextField, TextLink } from '@/components/ui';
import { describeError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

const MIN_PASSWORD = 8;

export default function RegisterScreen() {
  // Invitation links open bacalsys://register?invite=<token>. The token is sent
  // once in signup metadata; the database hashes it, claims it, then strips it.
  const { invite } = useLocalSearchParams<{ invite?: string }>();
  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const emailRef = useRef<TextInput>(null);
  const passwordRef = useRef<TextInput>(null);

  const nameError = fullName.length > 120 ? 'Keep your name under 120 characters.' : null;
  const passwordError =
    password.length > 0 && password.length < MIN_PASSWORD ? `Use at least ${MIN_PASSWORD} characters.` : null;
  const canSubmit =
    fullName.trim().length > 0 && email.trim().length > 0 && password.length >= MIN_PASSWORD && !nameError;

  async function onSubmit() {
    if (!canSubmit || submitting) return;
    setSubmitting(true);
    setError(null);
    setNotice(null);

    const { data, error: signUpError } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: {
        data: {
          full_name: fullName.trim(),
          ...(typeof invite === 'string' && invite.length > 0 ? { invite_token: invite } : {}),
        },
      },
    });

    if (signUpError) {
      setError(describeError(signUpError));
    } else if (!data.session) {
      // Projects with e-mail confirmation enabled return no session until the link is clicked.
      setNotice('Check your email to confirm your address, then sign in.');
    }
    // With a session, the route guard moves the user to pending-approval.
    setSubmitting(false);
  }

  return (
    <Screen>
      <View className="flex-1 justify-center">
        <Heading subtitle="Your application will be reviewed by a club officer.">Join BaCalSys</Heading>
        <View className="gap-4">
          {invite ? <Notice tone="success">Invitation detected. Use the email address it was sent to.</Notice> : null}
          {error ? <Notice tone="danger">{error}</Notice> : null}
          {notice ? <Notice tone="success">{notice}</Notice> : null}
          <TextField
            label="Full name"
            value={fullName}
            onChangeText={setFullName}
            error={nameError}
            autoComplete="name"
            textContentType="name"
            returnKeyType="next"
            onSubmitEditing={() => emailRef.current?.focus()}
          />
          <TextField
            ref={emailRef}
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
            error={passwordError}
            secureTextEntry
            autoComplete="new-password"
            textContentType="newPassword"
            returnKeyType="go"
            onSubmitEditing={onSubmit}
          />
          <Button label="Create account" onPress={onSubmit} loading={submitting} disabled={!canSubmit} />
        </View>
        <View className="mt-6 flex-row justify-center gap-1">
          <Text className="text-ink-muted">Already a member?</Text>
          <TextLink href="/login">Sign in</TextLink>
        </View>
      </View>
    </Screen>
  );
}
