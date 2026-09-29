import { Pressable, Text, View } from 'react-native';

import {
  CALENDAR_STATUS_COLOR,
  CALENDAR_STATUS_LABEL,
  type CalendarEntry,
  buildMonthGrid,
  monthLabel,
  resolveDayStatus,
} from '@/lib/training-stats';

/**
 * Sprint 6 · Task 6.11 — the month grid behind the Training Calendar screen
 * (Feature 7.1). Monday-first weeks; each day shows a single colored dot
 * resolved through the frozen precedence (`resolveDayStatus`) when it has one
 * or more entries, plus a small count badge when it has more than one. Purely
 * presentational: the screen owns data fetching, month navigation state and
 * what happens when a day or entry is tapped.
 */
export function TrainingCalendar({
  monthIso,
  entriesByDay,
  today,
  selected,
  onSelectDay,
  onPrevMonth,
  onNextMonth,
}: {
  monthIso: string;
  entriesByDay: Map<string, CalendarEntry[]>;
  /** The organization's calendar today, highlighted distinctly. */
  today: string;
  selected: string | null;
  onSelectDay: (date: string) => void;
  onPrevMonth: () => void;
  onNextMonth: () => void;
}) {
  const weeks = buildMonthGrid(monthIso);

  return (
    <View className="gap-3">
      <View className="flex-row items-center justify-between">
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Previous month"
          hitSlop={8}
          onPress={onPrevMonth}
          className="h-9 w-9 items-center justify-center rounded-full bg-surface-sunken active:opacity-70"
        >
          <Text className="text-lg text-ink">‹</Text>
        </Pressable>
        <Text className="text-title text-ink">{monthLabel(monthIso)}</Text>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Next month"
          hitSlop={8}
          onPress={onNextMonth}
          className="h-9 w-9 items-center justify-center rounded-full bg-surface-sunken active:opacity-70"
        >
          <Text className="text-lg text-ink">›</Text>
        </Pressable>
      </View>

      <View className="flex-row">
        {['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((d, i) => (
          <Text key={i} className="flex-1 text-center text-xs font-medium uppercase text-ink-faint">
            {d}
          </Text>
        ))}
      </View>

      <View className="gap-1">
        {weeks.map((week, wi) => (
          <View key={wi} className="flex-row">
            {week.map((date, di) => {
              if (!date) return <View key={di} className="aspect-square flex-1" />;
              const dayEntries = entriesByDay.get(date) ?? [];
              const status = resolveDayStatus(dayEntries.map((e) => e.status));
              const isToday = date === today;
              const isSelected = date === selected;
              const dayNumber = Number(date.slice(8, 10));
              return (
                <Pressable
                  key={di}
                  accessibilityRole="button"
                  accessibilityLabel={`${date}${status ? `, ${CALENDAR_STATUS_LABEL[status]}` : ''}`}
                  accessibilityState={{ selected: isSelected }}
                  onPress={() => onSelectDay(date)}
                  className={`aspect-square flex-1 items-center justify-center gap-1 rounded-control ${
                    isSelected ? 'bg-brand-soft' : isToday ? 'bg-surface-sunken' : ''
                  }`}
                >
                  <Text className={`text-sm ${isToday ? 'font-bold text-brand' : 'text-ink'}`}>{dayNumber}</Text>
                  <View className="h-3.5 flex-row items-center gap-0.5">
                    {status ? (
                      <View
                        accessible={false}
                        style={{ backgroundColor: CALENDAR_STATUS_COLOR[status] }}
                        className="h-1.5 w-1.5 rounded-full"
                      />
                    ) : null}
                    {dayEntries.length > 1 ? <Text className="text-[10px] leading-3 text-ink-faint">+{dayEntries.length - 1}</Text> : null}
                  </View>
                </Pressable>
              );
            })}
          </View>
        ))}
      </View>

      <View className="flex-row flex-wrap gap-x-3 gap-y-1 pt-1">
        {(Object.keys(CALENDAR_STATUS_LABEL) as (keyof typeof CALENDAR_STATUS_LABEL)[])
          .filter((s) => s !== 'in_progress')
          .map((s) => (
            <View key={s} className="flex-row items-center gap-1.5">
              <View style={{ backgroundColor: CALENDAR_STATUS_COLOR[s] }} className="h-2 w-2 rounded-full" />
              <Text className="text-xs text-ink-faint">{CALENDAR_STATUS_LABEL[s]}</Text>
            </View>
          ))}
      </View>
    </View>
  );
}
