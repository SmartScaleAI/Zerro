export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      generation_log: {
        Row: {
          created_at: string
          est_cost_usd: number | null
          id: string
          model: string | null
          provider: string | null
          subscription_id: string | null
          success: boolean
          tokens_in: number | null
          tokens_out: number | null
        }
        Insert: {
          created_at?: string
          est_cost_usd?: number | null
          id?: string
          model?: string | null
          provider?: string | null
          subscription_id?: string | null
          success: boolean
          tokens_in?: number | null
          tokens_out?: number | null
        }
        Update: {
          created_at?: string
          est_cost_usd?: number | null
          id?: string
          model?: string | null
          provider?: string | null
          subscription_id?: string | null
          success?: boolean
          tokens_in?: number | null
          tokens_out?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "generation_log_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id"]
          },
        ]
      }
      generation_slots: {
        Row: {
          acquired_at: string
          subscription_id: string
        }
        Insert: {
          acquired_at?: string
          subscription_id: string
        }
        Update: {
          acquired_at?: string
          subscription_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "generation_slots_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: true
            referencedRelation: "subscriptions"
            referencedColumns: ["id"]
          },
        ]
      }
      idempotency_cache: {
        Row: {
          created_at: string
          credits_remaining: number
          idempotency_key: string
          identity_key: string
          prompt: string
          usage: Json
        }
        Insert: {
          created_at?: string
          credits_remaining: number
          idempotency_key: string
          identity_key: string
          prompt: string
          usage: Json
        }
        Update: {
          created_at?: string
          credits_remaining?: number
          idempotency_key?: string
          identity_key?: string
          prompt?: string
          usage?: Json
        }
        Relationships: []
      }
      pending_license_keys: {
        Row: {
          created_at: string
          license_key_hash: string
          ls_customer_id: string | null
          ls_order_id: string
        }
        Insert: {
          created_at?: string
          license_key_hash: string
          ls_customer_id?: string | null
          ls_order_id: string
        }
        Update: {
          created_at?: string
          license_key_hash?: string
          ls_customer_id?: string | null
          ls_order_id?: string
        }
        Relationships: []
      }
      rate_limits: {
        Row: {
          count: number
          key: string
          window_start: string
        }
        Insert: {
          count?: number
          key: string
          window_start: string
        }
        Update: {
          count?: number
          key?: string
          window_start?: string
        }
        Relationships: []
      }
      subscriptions: {
        Row: {
          billing_interval: string | null
          created_at: string
          credits_limit: number
          current_period_end: string | null
          email_normalized: string | null
          id: string
          license_key_hash: string | null
          ls_customer_id: string | null
          ls_order_id: string | null
          ls_subscription_id: string
          ls_updated_at: string | null
          status: string
          tier: string
          updated_at: string
        }
        Insert: {
          billing_interval?: string | null
          created_at?: string
          credits_limit: number
          current_period_end?: string | null
          email_normalized?: string | null
          id?: string
          license_key_hash?: string | null
          ls_customer_id?: string | null
          ls_order_id?: string | null
          ls_subscription_id: string
          ls_updated_at?: string | null
          status: string
          tier: string
          updated_at?: string
        }
        Update: {
          billing_interval?: string | null
          created_at?: string
          credits_limit?: number
          current_period_end?: string | null
          email_normalized?: string | null
          id?: string
          license_key_hash?: string | null
          ls_customer_id?: string | null
          ls_order_id?: string | null
          ls_subscription_id?: string
          ls_updated_at?: string | null
          status?: string
          tier?: string
          updated_at?: string
        }
        Relationships: []
      }
      topup_credits: {
        Row: {
          created_at: string
          credits_total: number
          credits_used: number
          expires_at: string
          id: string
          ls_order_id: string | null
          purchased_at: string
          subscription_id: string
        }
        Insert: {
          created_at?: string
          credits_total: number
          credits_used?: number
          expires_at: string
          id?: string
          ls_order_id?: string | null
          purchased_at?: string
          subscription_id: string
        }
        Update: {
          created_at?: string
          credits_total?: number
          credits_used?: number
          expires_at?: string
          id?: string
          ls_order_id?: string | null
          purchased_at?: string
          subscription_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "topup_credits_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id"]
          },
        ]
      }
      trial_codes: {
        Row: {
          attempts: number
          code_hash: string
          created_at: string
          email_normalized: string
          expires_at: string
        }
        Insert: {
          attempts?: number
          code_hash: string
          created_at?: string
          email_normalized: string
          expires_at: string
        }
        Update: {
          attempts?: number
          code_hash?: string
          created_at?: string
          email_normalized?: string
          expires_at?: string
        }
        Relationships: []
      }
      trial_generation_slots: {
        Row: {
          acquired_at: string
          grant_id: string
        }
        Insert: {
          acquired_at?: string
          grant_id: string
        }
        Update: {
          acquired_at?: string
          grant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "trial_generation_slots_grant_id_fkey"
            columns: ["grant_id"]
            isOneToOne: true
            referencedRelation: "trial_grants"
            referencedColumns: ["id"]
          },
        ]
      }
      trial_grants: {
        Row: {
          created_at: string
          device_id_hash: string | null
          email_normalized: string
          id: string
          trial_credits_limit: number
          trial_credits_used: number
          verified_at: string | null
        }
        Insert: {
          created_at?: string
          device_id_hash?: string | null
          email_normalized: string
          id?: string
          trial_credits_limit: number
          trial_credits_used?: number
          verified_at?: string | null
        }
        Update: {
          created_at?: string
          device_id_hash?: string | null
          email_normalized?: string
          id?: string
          trial_credits_limit?: number
          trial_credits_used?: number
          verified_at?: string | null
        }
        Relationships: []
      }
      usage_periods: {
        Row: {
          created_at: string
          credits_used: number
          id: string
          period_end: string
          period_start: string
          subscription_id: string
        }
        Insert: {
          created_at?: string
          credits_used?: number
          id?: string
          period_end: string
          period_start: string
          subscription_id: string
        }
        Update: {
          created_at?: string
          credits_used?: number
          id?: string
          period_end?: string
          period_start?: string
          subscription_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "usage_periods_subscription_id_fkey"
            columns: ["subscription_id"]
            isOneToOne: false
            referencedRelation: "subscriptions"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_events: {
        Row: {
          event_name: string
          ls_event_id: string
          processed_at: string
        }
        Insert: {
          event_name: string
          ls_event_id: string
          processed_at?: string
        }
        Update: {
          event_name?: string
          ls_event_id?: string
          processed_at?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      acquire_generation_slot: {
        Args: { p_stale_seconds: number; p_subscription_id: string }
        Returns: boolean
      }
      acquire_trial_slot: {
        Args: { p_grant_id: string; p_stale_seconds: number }
        Returns: boolean
      }
      check_rate_limit: {
        Args: { p_key: string; p_max: number; p_window_seconds: number }
        Returns: boolean
      }
      consume_credit:
        | { Args: { p_subscription_id: string }; Returns: number }
        | {
            Args: { p_credits: number; p_subscription_id: string }
            Returns: number
          }
      consume_trial_credit:
        | { Args: { p_grant_id: string }; Returns: number }
        | { Args: { p_credits: number; p_grant_id: string }; Returns: number }
      prune_idempotency_cache: {
        Args: { p_ttl_seconds: number }
        Returns: undefined
      }
      release_generation_slot: {
        Args: { p_subscription_id: string }
        Returns: undefined
      }
      release_trial_slot: { Args: { p_grant_id: string }; Returns: undefined }
      verify_trial_grant: {
        Args: { p_email: string; p_limit: number; p_device_id_hash?: string }
        Returns: {
          credits_remaining: number
          grant_id: string
        }[]
      }
    }
    Enums: {
      [_ in never]: never
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
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
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
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
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
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
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
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
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
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {},
  },
} as const

