export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      assignment_occurrences: {
        Row: {
          assignment_id: string
          athlete_id: string
          completed_at: string | null
          created_at: string
          due_datetime: string
          id: string
          scheduled_at: string
          scheduled_date: string
          status: string
          updated_at: string
          workout_version_id: string
        }
        Insert: {
          assignment_id: string
          athlete_id: string
          completed_at?: string | null
          created_at?: string
          due_datetime: string
          id?: string
          scheduled_at: string
          scheduled_date: string
          status?: string
          updated_at?: string
          workout_version_id: string
        }
        Update: {
          assignment_id?: string
          athlete_id?: string
          completed_at?: string | null
          created_at?: string
          due_datetime?: string
          id?: string
          scheduled_at?: string
          scheduled_date?: string
          status?: string
          updated_at?: string
          workout_version_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "assignment_occurrences_assignment_id_fkey"
            columns: ["assignment_id"]
            isOneToOne: false
            referencedRelation: "workout_assignments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assignment_occurrences_athlete_id_fkey"
            columns: ["athlete_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assignment_occurrences_workout_version_id_fkey"
            columns: ["workout_version_id"]
            isOneToOne: false
            referencedRelation: "workout_versions"
            referencedColumns: ["id"]
          },
        ]
      }
      assignment_targets: {
        Row: {
          assignment_id: string
          athlete_id: string
          created_at: string
          id: string
        }
        Insert: {
          assignment_id: string
          athlete_id: string
          created_at?: string
          id?: string
        }
        Update: {
          assignment_id?: string
          athlete_id?: string
          created_at?: string
          id?: string
        }
        Relationships: [
          {
            foreignKeyName: "assignment_targets_assignment_id_fkey"
            columns: ["assignment_id"]
            isOneToOne: false
            referencedRelation: "workout_assignments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assignment_targets_athlete_id_fkey"
            columns: ["athlete_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_logs: {
        Row: {
          action: string
          actor_type: Database["public"]["Enums"]["audit_actor_type"]
          actor_user_id: string | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: string
          new_values: Json | null
          old_values: Json | null
        }
        Insert: {
          action: string
          actor_type: Database["public"]["Enums"]["audit_actor_type"]
          actor_user_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: string
          new_values?: Json | null
          old_values?: Json | null
        }
        Update: {
          action?: string
          actor_type?: Database["public"]["Enums"]["audit_actor_type"]
          actor_user_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: string
          new_values?: Json | null
          old_values?: Json | null
        }
        Relationships: []
      }
      branches: {
        Row: {
          created_at: string
          id: string
          is_default: boolean
          name: string
          organization_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_default?: boolean
          name: string
          organization_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_default?: boolean
          name?: string
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "branches_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      coach_assignments: {
        Row: {
          assigned_by: string
          athlete_id: string
          coach_id: string
          created_at: string
          ended_at: string | null
          ended_by: string | null
          id: string
          notes: string | null
          started_at: string
        }
        Insert: {
          assigned_by: string
          athlete_id: string
          coach_id: string
          created_at?: string
          ended_at?: string | null
          ended_by?: string | null
          id?: string
          notes?: string | null
          started_at?: string
        }
        Update: {
          assigned_by?: string
          athlete_id?: string
          coach_id?: string
          created_at?: string
          ended_at?: string | null
          ended_by?: string | null
          id?: string
          notes?: string | null
          started_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "coach_assignments_assigned_by_fkey"
            columns: ["assigned_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "coach_assignments_athlete_id_fkey"
            columns: ["athlete_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "coach_assignments_coach_id_fkey"
            columns: ["coach_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "coach_assignments_ended_by_fkey"
            columns: ["ended_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      exercises: {
        Row: {
          category: string
          created_at: string
          created_by: string | null
          description: string | null
          equipment_needed: string[]
          id: string
          is_official: boolean
          measurement_types: string[]
          name: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          slug: string
          status: string
        }
        Insert: {
          category: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          equipment_needed: string[]
          id?: string
          is_official?: boolean
          measurement_types: string[]
          name: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          slug: string
          status?: string
        }
        Update: {
          category?: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          equipment_needed?: string[]
          id?: string
          is_official?: boolean
          measurement_types?: string[]
          name?: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          slug?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "exercises_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "exercises_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      invitations: {
        Row: {
          claimed_at: string | null
          claimed_by: string | null
          created_at: string
          created_by: string
          email: string
          expires_at: string
          id: string
          preassigned_position_id: string | null
          token_hash: string
        }
        Insert: {
          claimed_at?: string | null
          claimed_by?: string | null
          created_at?: string
          created_by: string
          email: string
          expires_at: string
          id?: string
          preassigned_position_id?: string | null
          token_hash: string
        }
        Update: {
          claimed_at?: string | null
          claimed_by?: string | null
          created_at?: string
          created_by?: string
          email?: string
          expires_at?: string
          id?: string
          preassigned_position_id?: string | null
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "invitations_claimed_by_fkey"
            columns: ["claimed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_preassigned_position_id_fkey"
            columns: ["preassigned_position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      member_positions: {
        Row: {
          assigned_at: string
          assigned_by: string | null
          end_reason: string | null
          ended_at: string | null
          ended_by: string | null
          id: string
          position_id: string
          profile_id: string
        }
        Insert: {
          assigned_at?: string
          assigned_by?: string | null
          end_reason?: string | null
          ended_at?: string | null
          ended_by?: string | null
          id?: string
          position_id: string
          profile_id: string
        }
        Update: {
          assigned_at?: string
          assigned_by?: string | null
          end_reason?: string | null
          ended_at?: string | null
          ended_by?: string | null
          id?: string
          position_id?: string
          profile_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_positions_assigned_by_fkey"
            columns: ["assigned_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_positions_ended_by_fkey"
            columns: ["ended_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_positions_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_positions_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string
          id: string
          name: string
          slug: string
          timezone: string
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          slug: string
          timezone?: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          slug?: string
          timezone?: string
        }
        Relationships: []
      }
      permissions: {
        Row: {
          created_at: string
          description: string
          id: string
          name: string
        }
        Insert: {
          created_at?: string
          description?: string
          id?: string
          name: string
        }
        Update: {
          created_at?: string
          description?: string
          id?: string
          name?: string
        }
        Relationships: []
      }
      position_permissions: {
        Row: {
          created_at: string
          permission_id: string
          position_id: string
        }
        Insert: {
          created_at?: string
          permission_id: string
          position_id: string
        }
        Update: {
          created_at?: string
          permission_id?: string
          position_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "position_permissions_permission_id_fkey"
            columns: ["permission_id"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "position_permissions_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "positions"
            referencedColumns: ["id"]
          },
        ]
      }
      positions: {
        Row: {
          created_at: string
          description: string
          id: string
          name: string
          rank: number
        }
        Insert: {
          created_at?: string
          description?: string
          id?: string
          name: string
          rank: number
        }
        Update: {
          created_at?: string
          description?: string
          id?: string
          name?: string
          rank?: number
        }
        Relationships: []
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          full_name: string
          home_branch_id: string | null
          id: string
          status: Database["public"]["Enums"]["member_status"]
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          full_name?: string
          home_branch_id?: string | null
          id: string
          status?: Database["public"]["Enums"]["member_status"]
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          full_name?: string
          home_branch_id?: string | null
          id?: string
          status?: Database["public"]["Enums"]["member_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "profiles_home_branch_id_fkey"
            columns: ["home_branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
        ]
      }
      recurring_schedules: {
        Row: {
          assignment_id: string
          created_at: string
          days_of_week: number[]
          end_date: string | null
          id: string
          is_active: boolean
          start_date: string
          timezone: string
          updated_at: string
        }
        Insert: {
          assignment_id: string
          created_at?: string
          days_of_week: number[]
          end_date?: string | null
          id?: string
          is_active?: boolean
          start_date: string
          timezone?: string
          updated_at?: string
        }
        Update: {
          assignment_id?: string
          created_at?: string
          days_of_week?: number[]
          end_date?: string | null
          id?: string
          is_active?: boolean
          start_date?: string
          timezone?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "recurring_schedules_assignment_id_fkey"
            columns: ["assignment_id"]
            isOneToOne: true
            referencedRelation: "workout_assignments"
            referencedColumns: ["id"]
          },
        ]
      }
      session_exercises: {
        Row: {
          created_at: string
          exercise_id: string
          id: string
          is_substituted: boolean
          order_in_session: number
          performed_measurement_mode: string
          session_id: string
          workout_item_id: string
        }
        Insert: {
          created_at?: string
          exercise_id: string
          id?: string
          is_substituted?: boolean
          order_in_session: number
          performed_measurement_mode: string
          session_id: string
          workout_item_id: string
        }
        Update: {
          created_at?: string
          exercise_id?: string
          id?: string
          is_substituted?: boolean
          order_in_session?: number
          performed_measurement_mode?: string
          session_id?: string
          workout_item_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_exercises_exercise_id_fkey"
            columns: ["exercise_id"]
            isOneToOne: false
            referencedRelation: "exercises"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_exercises_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "workout_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_exercises_workout_item_id_fkey"
            columns: ["workout_item_id"]
            isOneToOne: false
            referencedRelation: "workout_items"
            referencedColumns: ["id"]
          },
        ]
      }
      session_feedback: {
        Row: {
          created_at: string
          difficulty_rating: number
          energy_level: number
          session_id: string
        }
        Insert: {
          created_at?: string
          difficulty_rating: number
          energy_level: number
          session_id: string
        }
        Update: {
          created_at?: string
          difficulty_rating?: number
          energy_level?: number
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_feedback_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: true
            referencedRelation: "workout_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      session_modifications: {
        Row: {
          created_at: string
          id: string
          original_workout_item_id: string
          reason_code: string
          replacement_exercise_id: string
          session_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          original_workout_item_id: string
          reason_code: string
          replacement_exercise_id: string
          session_id: string
        }
        Update: {
          created_at?: string
          id?: string
          original_workout_item_id?: string
          reason_code?: string
          replacement_exercise_id?: string
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_modifications_original_workout_item_id_fkey"
            columns: ["original_workout_item_id"]
            isOneToOne: false
            referencedRelation: "workout_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_modifications_replacement_exercise_id_fkey"
            columns: ["replacement_exercise_id"]
            isOneToOne: false
            referencedRelation: "exercises"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_modifications_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "workout_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      session_private_feedback: {
        Row: {
          created_at: string
          discomfort_area: string | null
          has_discomfort: boolean
          note_to_coach: string | null
          session_id: string
        }
        Insert: {
          created_at?: string
          discomfort_area?: string | null
          has_discomfort?: boolean
          note_to_coach?: string | null
          session_id: string
        }
        Update: {
          created_at?: string
          discomfort_area?: string | null
          has_discomfort?: boolean
          note_to_coach?: string | null
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "session_private_feedback_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: true
            referencedRelation: "workout_sessions"
            referencedColumns: ["id"]
          },
        ]
      }
      session_sets: {
        Row: {
          actual_distance_meters: number | null
          actual_duration_seconds: number | null
          actual_load_kg: number | null
          actual_reps: number | null
          actual_rest_seconds: number | null
          created_at: string
          id: string
          is_completed: boolean
          load_type: string | null
          prescribed_item_set_id: string | null
          rpe: number | null
          session_exercise_id: string
          set_number: number
        }
        Insert: {
          actual_distance_meters?: number | null
          actual_duration_seconds?: number | null
          actual_load_kg?: number | null
          actual_reps?: number | null
          actual_rest_seconds?: number | null
          created_at?: string
          id?: string
          is_completed?: boolean
          load_type?: string | null
          prescribed_item_set_id?: string | null
          rpe?: number | null
          session_exercise_id: string
          set_number: number
        }
        Update: {
          actual_distance_meters?: number | null
          actual_duration_seconds?: number | null
          actual_load_kg?: number | null
          actual_reps?: number | null
          actual_rest_seconds?: number | null
          created_at?: string
          id?: string
          is_completed?: boolean
          load_type?: string | null
          prescribed_item_set_id?: string | null
          rpe?: number | null
          session_exercise_id?: string
          set_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "session_sets_prescribed_item_set_id_fkey"
            columns: ["prescribed_item_set_id"]
            isOneToOne: false
            referencedRelation: "workout_item_sets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "session_sets_session_exercise_id_fkey"
            columns: ["session_exercise_id"]
            isOneToOne: false
            referencedRelation: "session_exercises"
            referencedColumns: ["id"]
          },
        ]
      }
      system_role_permissions: {
        Row: {
          created_at: string
          permission_id: string
          role_id: string
        }
        Insert: {
          created_at?: string
          permission_id: string
          role_id: string
        }
        Update: {
          created_at?: string
          permission_id?: string
          role_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "system_role_permissions_permission_id_fkey"
            columns: ["permission_id"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "system_role_permissions_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "system_roles"
            referencedColumns: ["id"]
          },
        ]
      }
      system_roles: {
        Row: {
          created_at: string
          description: string
          id: string
          name: string
        }
        Insert: {
          created_at?: string
          description?: string
          id?: string
          name: string
        }
        Update: {
          created_at?: string
          description?: string
          id?: string
          name?: string
        }
        Relationships: []
      }
      user_system_roles: {
        Row: {
          assigned_at: string
          assigned_by: string | null
          end_reason: string | null
          ended_at: string | null
          ended_by: string | null
          id: string
          role_id: string
          user_id: string
        }
        Insert: {
          assigned_at?: string
          assigned_by?: string | null
          end_reason?: string | null
          ended_at?: string | null
          ended_by?: string | null
          id?: string
          role_id: string
          user_id: string
        }
        Update: {
          assigned_at?: string
          assigned_by?: string | null
          end_reason?: string | null
          ended_at?: string | null
          ended_by?: string | null
          id?: string
          role_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_system_roles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "system_roles"
            referencedColumns: ["id"]
          },
        ]
      }
      workout_assignments: {
        Row: {
          assigned_by: string
          created_at: string
          id: string
          is_recurring: boolean
          notes: string | null
          organization_id: string
          status: string
          target_date: string | null
          updated_at: string
          workout_template_id: string
          workout_version_id: string
        }
        Insert: {
          assigned_by: string
          created_at?: string
          id?: string
          is_recurring?: boolean
          notes?: string | null
          organization_id: string
          status?: string
          target_date?: string | null
          updated_at?: string
          workout_template_id: string
          workout_version_id: string
        }
        Update: {
          assigned_by?: string
          created_at?: string
          id?: string
          is_recurring?: boolean
          notes?: string | null
          organization_id?: string
          status?: string
          target_date?: string | null
          updated_at?: string
          workout_template_id?: string
          workout_version_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "workout_assignments_assigned_by_fkey"
            columns: ["assigned_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_assignments_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_assignments_workout_template_id_fkey"
            columns: ["workout_template_id"]
            isOneToOne: false
            referencedRelation: "workout_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_assignments_workout_version_id_fkey"
            columns: ["workout_version_id"]
            isOneToOne: false
            referencedRelation: "workout_versions"
            referencedColumns: ["id"]
          },
        ]
      }
      workout_blocks: {
        Row: {
          amrap_duration_seconds: number | null
          block_type: string
          circuit_rounds: number | null
          created_at: string
          id: string
          notes: string | null
          order_in_workout: number
          title: string
          workout_version_id: string
        }
        Insert: {
          amrap_duration_seconds?: number | null
          block_type: string
          circuit_rounds?: number | null
          created_at?: string
          id?: string
          notes?: string | null
          order_in_workout: number
          title: string
          workout_version_id: string
        }
        Update: {
          amrap_duration_seconds?: number | null
          block_type?: string
          circuit_rounds?: number | null
          created_at?: string
          id?: string
          notes?: string | null
          order_in_workout?: number
          title?: string
          workout_version_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "workout_blocks_workout_version_id_fkey"
            columns: ["workout_version_id"]
            isOneToOne: false
            referencedRelation: "workout_versions"
            referencedColumns: ["id"]
          },
        ]
      }
      workout_item_sets: {
        Row: {
          created_at: string
          id: string
          load_type: string | null
          notes: string | null
          set_number: number
          target_distance_meters: number | null
          target_duration_seconds: number | null
          target_load_kg: number | null
          target_reps: number | null
          target_rest_seconds: number | null
          target_rpe: number | null
          workout_item_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          load_type?: string | null
          notes?: string | null
          set_number: number
          target_distance_meters?: number | null
          target_duration_seconds?: number | null
          target_load_kg?: number | null
          target_reps?: number | null
          target_rest_seconds?: number | null
          target_rpe?: number | null
          workout_item_id: string
        }
        Update: {
          created_at?: string
          id?: string
          load_type?: string | null
          notes?: string | null
          set_number?: number
          target_distance_meters?: number | null
          target_duration_seconds?: number | null
          target_load_kg?: number | null
          target_reps?: number | null
          target_rest_seconds?: number | null
          target_rpe?: number | null
          workout_item_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "workout_item_sets_workout_item_id_fkey"
            columns: ["workout_item_id"]
            isOneToOne: false
            referencedRelation: "workout_items"
            referencedColumns: ["id"]
          },
        ]
      }
      workout_items: {
        Row: {
          block_id: string
          created_at: string
          exercise_id: string
          id: string
          measurement_mode: string
          notes: string | null
          order_in_block: number
        }
        Insert: {
          block_id: string
          created_at?: string
          exercise_id: string
          id?: string
          measurement_mode: string
          notes?: string | null
          order_in_block: number
        }
        Update: {
          block_id?: string
          created_at?: string
          exercise_id?: string
          id?: string
          measurement_mode?: string
          notes?: string | null
          order_in_block?: number
        }
        Relationships: [
          {
            foreignKeyName: "workout_items_block_id_fkey"
            columns: ["block_id"]
            isOneToOne: false
            referencedRelation: "workout_blocks"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_items_exercise_id_fkey"
            columns: ["exercise_id"]
            isOneToOne: false
            referencedRelation: "exercises"
            referencedColumns: ["id"]
          },
        ]
      }
      workout_sessions: {
        Row: {
          abandonment_reason_code: string | null
          assignment_occurrence_id: string | null
          athlete_id: string
          completed_at: string | null
          created_at: string
          id: string
          started_at: string
          status: string
          updated_at: string
          workout_version_id: string
        }
        Insert: {
          abandonment_reason_code?: string | null
          assignment_occurrence_id?: string | null
          athlete_id: string
          completed_at?: string | null
          created_at?: string
          id?: string
          started_at?: string
          status?: string
          updated_at?: string
          workout_version_id: string
        }
        Update: {
          abandonment_reason_code?: string | null
          assignment_occurrence_id?: string | null
          athlete_id?: string
          completed_at?: string | null
          created_at?: string
          id?: string
          started_at?: string
          status?: string
          updated_at?: string
          workout_version_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_workout_sessions_assignment_occurrence"
            columns: ["assignment_occurrence_id"]
            isOneToOne: false
            referencedRelation: "assignment_occurrences"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_sessions_athlete_id_fkey"
            columns: ["athlete_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_sessions_workout_version_id_fkey"
            columns: ["workout_version_id"]
            isOneToOne: false
            referencedRelation: "workout_versions"
            referencedColumns: ["id"]
          },
        ]
      }
      workout_templates: {
        Row: {
          created_at: string
          created_by: string
          description: string | null
          id: string
          is_archived: boolean
          name: string
          organization_id: string
          updated_at: string
          visibility: string
        }
        Insert: {
          created_at?: string
          created_by: string
          description?: string | null
          id?: string
          is_archived?: boolean
          name: string
          organization_id: string
          updated_at?: string
          visibility?: string
        }
        Update: {
          created_at?: string
          created_by?: string
          description?: string | null
          id?: string
          is_archived?: boolean
          name?: string
          organization_id?: string
          updated_at?: string
          visibility?: string
        }
        Relationships: [
          {
            foreignKeyName: "workout_templates_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_templates_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      workout_versions: {
        Row: {
          created_at: string
          created_by: string
          id: string
          is_sealed: boolean
          notes: string | null
          sealed_at: string | null
          template_id: string
          version_number: number
        }
        Insert: {
          created_at?: string
          created_by: string
          id?: string
          is_sealed?: boolean
          notes?: string | null
          sealed_at?: string | null
          template_id: string
          version_number: number
        }
        Update: {
          created_at?: string
          created_by?: string
          id?: string
          is_sealed?: boolean
          notes?: string | null
          sealed_at?: string | null
          template_id?: string
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "workout_versions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workout_versions_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "workout_templates"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      approve_member: { Args: { p_profile_id: string }; Returns: Json }
      assign_primary_coach: {
        Args: { p_athlete_id: string; p_coach_id: string; p_notes?: string }
        Returns: string
      }
      cancel_workout_assignment: {
        Args: { p_assignment_id: string; p_idempotency_key: string }
        Returns: Json
      }
      clone_workout_template: {
        Args: { p_new_name?: string; p_template_id: string }
        Returns: Json
      }
      complete_workout_session: {
        Args: {
          p_abandonment_reason_code: string
          p_feedback: Json
          p_idempotency_key: string
          p_private_feedback: Json
          p_session_id: string
          p_status: string
        }
        Returns: Json
      }
      create_invitation: {
        Args: {
          p_email: string
          p_expires_in_hours?: number
          p_preassigned_position_id?: string
        }
        Returns: Json
      }
      create_workout_assignment: {
        Args: {
          p_idempotency_key: string
          p_is_recurring: boolean
          p_notes: string
          p_recurrence_rule: Json
          p_target_athlete_ids: string[]
          p_target_date: string
          p_workout_template_id: string
          p_workout_version_id: string
        }
        Returns: Json
      }
      create_workout_template: {
        Args: {
          p_blocks: Json
          p_description: string
          p_name: string
          p_visibility: string
        }
        Returns: Json
      }
      get_my_access_context: { Args: never; Returns: Json }
      list_pending_members: {
        Args: never
        Returns: {
          branch_name: string
          created_at: string
          email: string
          full_name: string
          home_branch_id: string
          id: string
        }[]
      }
      migrate_assignment_version: {
        Args: {
          p_assignment_id: string
          p_idempotency_key: string
          p_migration_choice: string
          p_new_version_id: string
          p_selected_occurrence_ids: string[]
        }
        Returns: Json
      }
      publish_new_workout_version: {
        Args: { p_blocks: Json; p_template_id: string; p_version_notes: string }
        Returns: Json
      }
      record_exercise_substitution: {
        Args: {
          p_idempotency_key: string
          p_original_workout_item_id: string
          p_performed_measurement_mode: string
          p_reason_code: string
          p_replacement_exercise_id: string
          p_session_id: string
        }
        Returns: Json
      }
      record_session_set: {
        Args: {
          p_idempotency_key: string
          p_session_exercise_id: string
          p_session_id: string
          p_set_data: Json
        }
        Returns: Json
      }
      review_custom_exercise: {
        Args: {
          p_action: string
          p_exercise_id: string
          p_rejection_reason?: string
        }
        Returns: {
          category: string
          created_at: string
          created_by: string | null
          description: string | null
          equipment_needed: string[]
          id: string
          is_official: boolean
          measurement_types: string[]
          name: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          slug: string
          status: string
        }
        SetofOptions: {
          from: "*"
          to: "exercises"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_template_visibility: {
        Args: { p_template_id: string; p_visibility: string }
        Returns: {
          created_at: string
          created_by: string
          description: string | null
          id: string
          is_archived: boolean
          name: string
          organization_id: string
          updated_at: string
          visibility: string
        }
        SetofOptions: {
          from: "*"
          to: "workout_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_workout_template_archived: {
        Args: { p_is_archived: boolean; p_template_id: string }
        Returns: {
          created_at: string
          created_by: string
          description: string | null
          id: string
          is_archived: boolean
          name: string
          organization_id: string
          updated_at: string
          visibility: string
        }
        SetofOptions: {
          from: "*"
          to: "workout_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      start_workout_session:
        | {
            Args: { p_idempotency_key: string; p_workout_version_id: string }
            Returns: Json
          }
        | {
            Args: {
              p_assignment_occurrence_id: string
              p_idempotency_key: string
              p_workout_version_id: string
            }
            Returns: Json
          }
      submit_custom_exercise: {
        Args: { p_exercise_id: string }
        Returns: {
          category: string
          created_at: string
          created_by: string | null
          description: string | null
          equipment_needed: string[]
          id: string
          is_official: boolean
          measurement_types: string[]
          name: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          slug: string
          status: string
        }
        SetofOptions: {
          from: "*"
          to: "exercises"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      sync_offline_session_bundle: {
        Args: { p_bundle: Json; p_idempotency_key: string }
        Returns: Json
      }
      update_workout_template_metadata: {
        Args: { p_description: string; p_name: string; p_template_id: string }
        Returns: {
          created_at: string
          created_by: string
          description: string | null
          id: string
          is_archived: boolean
          name: string
          organization_id: string
          updated_at: string
          visibility: string
        }
        SetofOptions: {
          from: "*"
          to: "workout_templates"
          isOneToOne: true
          isSetofReturn: false
        }
      }
    }
    Enums: {
      audit_actor_type: "user" | "system" | "cron" | "migration"
      member_status: "pending_approval" | "active" | "suspended" | "rejected"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      audit_actor_type: ["user", "system", "cron", "migration"],
      member_status: ["pending_approval", "active", "suspended", "rejected"],
    },
  },
} as const
