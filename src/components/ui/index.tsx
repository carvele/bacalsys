import { forwardRef, type ReactNode } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  Text,
  TextInput,
  View,
  type TextInputProps,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

/** Full-height screen with safe-area padding and a centered, width-capped column (web/tablet). */
export function Screen({ children, scroll = true }: { children: ReactNode; scroll?: boolean }) {
  const body = <View className="w-full max-w-[480px] flex-1 self-center px-4 py-6">{children}</View>;
  return (
    <SafeAreaView className="flex-1 bg-surface">
      <KeyboardAvoidingView className="flex-1" behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        {scroll ? (
          <ScrollView contentContainerClassName="flex-grow" keyboardShouldPersistTaps="handled">
            {body}
          </ScrollView>
        ) : (
          body
        )}
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

export function Heading({ children, subtitle }: { children: ReactNode; subtitle?: ReactNode }) {
  return (
    <View className="mb-6 gap-1">
      <Text accessibilityRole="header" className="text-display text-ink">
        {children}
      </Text>
      {subtitle ? <Text className="text-base text-ink-muted">{subtitle}</Text> : null}
    </View>
  );
}

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <View className={`rounded-card border border-surface-border bg-surface-raised p-4 ${className}`}>{children}</View>;
}

type ButtonVariant = 'primary' | 'secondary' | 'danger' | 'ghost';

const buttonStyles: Record<ButtonVariant, { box: string; text: string }> = {
  primary: { box: 'bg-brand active:bg-brand-pressed', text: 'text-white' },
  secondary: { box: 'border border-surface-border bg-surface-raised active:bg-surface-sunken', text: 'text-ink' },
  danger: { box: 'bg-danger active:opacity-80', text: 'text-white' },
  ghost: { box: 'active:bg-surface-raised', text: 'text-brand' },
};

export function Button({
  label,
  onPress,
  variant = 'primary',
  loading = false,
  disabled = false,
  accessibilityHint,
}: {
  label: string;
  onPress: () => void;
  variant?: ButtonVariant;
  loading?: boolean;
  disabled?: boolean;
  accessibilityHint?: string;
}) {
  const inactive = disabled || loading;
  const s = buttonStyles[variant];
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={accessibilityHint}
      accessibilityState={{ disabled: inactive, busy: loading }}
      disabled={inactive}
      onPress={onPress}
      className={`min-h-12 flex-row items-center justify-center rounded-control px-4 ${s.box} ${inactive ? 'opacity-50' : ''}`}
    >
      {loading ? (
        <ActivityIndicator color={variant === 'secondary' || variant === 'ghost' ? '#E8EDF2' : '#FFFFFF'} />
      ) : (
        <Text className={`text-base font-semibold ${s.text}`}>{label}</Text>
      )}
    </Pressable>
  );
}

export const TextField = forwardRef<TextInput, TextInputProps & { label: string; error?: string | null }>(
  function TextField({ label, error, ...props }, ref) {
    return (
      <View className="gap-1.5">
        <Text className="text-sm font-medium text-ink-muted">{label}</Text>
        <TextInput
          ref={ref}
          accessibilityLabel={label}
          placeholderTextColor="#5E6C7A"
          className={`min-h-12 rounded-control border bg-surface-sunken px-3 text-base text-ink ${
            error ? 'border-danger' : 'border-surface-border focus:border-brand'
          }`}
          {...props}
        />
        {error ? <Text className="text-sm text-danger">{error}</Text> : null}
      </View>
    );
  },
);

export function Notice({ tone, children }: { tone: 'danger' | 'success' | 'warning'; children: ReactNode }) {
  const styles = {
    danger: 'border-danger bg-danger-soft text-danger',
    success: 'border-success bg-success-soft text-success',
    warning: 'border-warning bg-warning-soft text-warning',
  }[tone];
  const [border, bg, text] = styles.split(' ');
  return (
    <View accessibilityRole="alert" className={`rounded-control border px-3 py-2.5 ${border} ${bg}`}>
      <Text className={`text-sm ${text}`}>{children}</Text>
    </View>
  );
}

export function CenteredSpinner({ label }: { label?: string }) {
  return (
    <View className="flex-1 items-center justify-center gap-3 bg-surface">
      <ActivityIndicator size="large" color="#F97316" />
      {label ? <Text className="text-ink-muted">{label}</Text> : null}
    </View>
  );
}
