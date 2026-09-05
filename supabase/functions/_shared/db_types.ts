export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  billing: {
    Tables: {
      accounts: {
        Row: {
          created_at: string
          id: string
          name: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          updated_at?: string
        }
        Relationships: []
      }
      costs: {
        Row: {
          created_at: string
          effective_at: string
          pricing: Json
          product: string
          provider: string
          quantity: number
          unit: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          effective_at?: string
          pricing: Json
          product: string
          provider: string
          quantity: number
          unit: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          effective_at?: string
          pricing?: Json
          product?: string
          provider?: string
          quantity?: number
          unit?: string
          updated_at?: string
        }
        Relationships: []
      }
      invoices: {
        Row: {
          created_at: string
          id: string
          organization_id: string
          period_end: string | null
          period_start: string | null
          status: string
          subtotal: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          organization_id: string
          period_end?: string | null
          period_start?: string | null
          status?: string
          subtotal?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          organization_id?: string
          period_end?: string | null
          period_start?: string | null
          status?: string
          subtotal?: number
          updated_at?: string
        }
        Relationships: []
      }
      invoices_items: {
        Row: {
          amount: number
          created_at: string
          id: string
          invoice_id: string
          ledger_id: string | null
          plan_id: string | null
          product_id: string | null
          quantity: number
          type: string
          unit_price: number
          updated_at: string
        }
        Insert: {
          amount: number
          created_at?: string
          id?: string
          invoice_id: string
          ledger_id?: string | null
          plan_id?: string | null
          product_id?: string | null
          quantity: number
          type: string
          unit_price: number
          updated_at?: string
        }
        Update: {
          amount?: number
          created_at?: string
          id?: string
          invoice_id?: string
          ledger_id?: string | null
          plan_id?: string | null
          product_id?: string | null
          quantity?: number
          type?: string
          unit_price?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "invoices_items_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_items_ledger_id_fkey"
            columns: ["ledger_id"]
            isOneToOne: false
            referencedRelation: "ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_items_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      ledger: {
        Row: {
          agent_id: string | null
          billable: boolean | null
          created_at: string
          id: string
          message_id: string | null
          metadata: Json | null
          model: string | null
          organization_id: string
          product_id: string
          provider: string | null
          quantity: number
          type: string
          updated_at: string
        }
        Insert: {
          agent_id?: string | null
          billable?: boolean | null
          created_at?: string
          id?: string
          message_id?: string | null
          metadata?: Json | null
          model?: string | null
          organization_id: string
          product_id: string
          provider?: string | null
          quantity: number
          type: string
          updated_at?: string
        }
        Update: {
          agent_id?: string | null
          billable?: boolean | null
          created_at?: string
          id?: string
          message_id?: string | null
          metadata?: Json | null
          model?: string | null
          organization_id?: string
          product_id?: string
          provider?: string | null
          quantity?: number
          type?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "ledger_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          account_id: string | null
          amount: number
          created_at: string
          external_id: string | null
          id: string
          invoice_id: string
          method: string | null
          organization_id: string
          status: string
          updated_at: string
        }
        Insert: {
          account_id?: string | null
          amount: number
          created_at?: string
          external_id?: string | null
          id?: string
          invoice_id: string
          method?: string | null
          organization_id: string
          status?: string
          updated_at?: string
        }
        Update: {
          account_id?: string | null
          amount?: number
          created_at?: string
          external_id?: string | null
          id?: string
          invoice_id?: string
          method?: string | null
          organization_id?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payments_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
        ]
      }
      plans: {
        Row: {
          active: boolean
          billing_cycle: string | null
          created_at: string
          id: string
          is_default: boolean
          min_tier: number
          price: number
          updated_at: string
        }
        Insert: {
          active?: boolean
          billing_cycle?: string | null
          created_at?: string
          id: string
          is_default?: boolean
          min_tier: number
          price: number
          updated_at?: string
        }
        Update: {
          active?: boolean
          billing_cycle?: string | null
          created_at?: string
          id?: string
          is_default?: boolean
          min_tier?: number
          price?: number
          updated_at?: string
        }
        Relationships: []
      }
      plans_products: {
        Row: {
          created_at: string
          included: number | null
          interval: string
          plan_id: string
          product_id: string
          unit_price: number | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          included?: number | null
          interval: string
          plan_id: string
          product_id: string
          unit_price?: number | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          included?: number | null
          interval?: string
          plan_id?: string
          product_id?: string
          unit_price?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "plans_products_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plans_products_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      products: {
        Row: {
          created_at: string
          id: string
          kind: string
          name: string
          unit: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          id: string
          kind: string
          name: string
          unit: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          kind?: string
          name?: string
          unit?: string
          updated_at?: string
        }
        Relationships: []
      }
      subscriptions: {
        Row: {
          account_id: string | null
          created_at: string
          current_period_end: string | null
          current_period_start: string | null
          organization_id: string
          plan_id: string | null
          tier_id: string
          updated_at: string
        }
        Insert: {
          account_id?: string | null
          created_at?: string
          current_period_end?: string | null
          current_period_start?: string | null
          organization_id: string
          plan_id?: string | null
          tier_id: string
          updated_at?: string
        }
        Update: {
          account_id?: string | null
          created_at?: string
          current_period_end?: string | null
          current_period_start?: string | null
          organization_id?: string
          plan_id?: string | null
          tier_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "subscriptions_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscriptions_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscriptions_tier_id_fkey"
            columns: ["tier_id"]
            isOneToOne: false
            referencedRelation: "tiers"
            referencedColumns: ["id"]
          },
        ]
      }
      tiers: {
        Row: {
          active: boolean
          created_at: string
          id: string
          level: number
          name: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id: string
          level?: number
          name: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          level?: number
          name?: string
          updated_at?: string
        }
        Relationships: []
      }
      tiers_products: {
        Row: {
          cap: number | null
          created_at: string
          interval: string
          product_id: string
          tier_id: string
          updated_at: string
        }
        Insert: {
          cap?: number | null
          created_at?: string
          interval: string
          product_id: string
          tier_id: string
          updated_at?: string
        }
        Update: {
          cap?: number | null
          created_at?: string
          interval?: string
          product_id?: string
          tier_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "tiers_products_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tiers_products_tier_id_fkey"
            columns: ["tier_id"]
            isOneToOne: false
            referencedRelation: "tiers"
            referencedColumns: ["id"]
          },
        ]
      }
      usage: {
        Row: {
          created_at: string
          interval: string
          organization_id: string
          period: string
          product_id: string
          quantity: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          interval?: string
          organization_id: string
          period?: string
          product_id: string
          quantity?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          interval?: string
          organization_id?: string
          period?: string
          product_id?: string
          quantity?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "usage_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      change_plan: {
        Args: { _organization_id: string; _plan_id: string }
        Returns: undefined
      }
      check_limit: {
        Args: {
          _amount?: number
          _organization_id: string
          _product_id: string
        }
        Returns: boolean
      }
      update_usage: {
        Args: {
          _organization_id: string
          _product_id: string
          _quantity?: number
        }
        Returns: undefined
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
      agent_assignment_presence: {
        Row: {
          agent_id: string
          available: boolean
          last_heartbeat_at: string | null
          organization_id: string
          updated_at: string
        }
        Insert: {
          agent_id: string
          available?: boolean
          last_heartbeat_at?: string | null
          organization_id: string
          updated_at?: string
        }
        Update: {
          agent_id?: string
          available?: boolean
          last_heartbeat_at?: string | null
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_assignment_presence_organization_id_agent_id_fkey"
            columns: ["organization_id", "agent_id"]
            isOneToOne: true
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      agents: {
        Row: {
          ai: boolean
          created_at: string
          extra: Json | null
          id: string
          name: string
          organization_id: string
          picture: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          ai: boolean
          created_at?: string
          extra?: Json | null
          id?: string
          name: string
          organization_id: string
          picture?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          ai?: boolean
          created_at?: string
          extra?: Json | null
          id?: string
          name?: string
          organization_id?: string
          picture?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "agents_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      api_keys: {
        Row: {
          created_at: string
          id: string
          key: string
          name: string
          organization_id: string
          role: Database["public"]["Enums"]["role"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          key: string
          name: string
          organization_id: string
          role?: Database["public"]["Enums"]["role"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          key?: string
          name?: string
          organization_id?: string
          role?: Database["public"]["Enums"]["role"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "api_keys_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      campaign_csv_recipients: {
        Row: {
          campaign_id: string
          contact_address: string
          created_at: string
          id: string
          name: string | null
          organization_id: string
          updated_at: string
          variables: Json
        }
        Insert: {
          campaign_id: string
          contact_address: string
          created_at?: string
          id?: string
          name?: string | null
          organization_id: string
          updated_at?: string
          variables?: Json
        }
        Update: {
          campaign_id?: string
          contact_address?: string
          created_at?: string
          id?: string
          name?: string | null
          organization_id?: string
          updated_at?: string
          variables?: Json
        }
        Relationships: [
          {
            foreignKeyName: "campaign_csv_recipients_campaign_fkey"
            columns: ["organization_id", "campaign_id"]
            isOneToOne: false
            referencedRelation: "campaigns"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      campaign_deliveries: {
        Row: {
          attempts: number
          campaign_id: string
          contact_address: string
          created_at: string
          error: Json | null
          external_id: string | null
          id: string
          name: string | null
          organization_id: string
          status: string
          updated_at: string
          variables: Json
        }
        Insert: {
          attempts?: number
          campaign_id: string
          contact_address: string
          created_at?: string
          error?: Json | null
          external_id?: string | null
          id?: string
          name?: string | null
          organization_id: string
          status?: string
          updated_at?: string
          variables?: Json
        }
        Update: {
          attempts?: number
          campaign_id?: string
          contact_address?: string
          created_at?: string
          error?: Json | null
          external_id?: string | null
          id?: string
          name?: string | null
          organization_id?: string
          status?: string
          updated_at?: string
          variables?: Json
        }
        Relationships: [
          {
            foreignKeyName: "campaign_deliveries_campaign_fkey"
            columns: ["organization_id", "campaign_id"]
            isOneToOne: false
            referencedRelation: "campaigns"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      campaigns: {
        Row: {
          accepted_count: number
          audience_type: Database["public"]["Enums"]["campaign_audience_type"]
          created_at: string
          created_by: string | null
          failed_count: number
          header_media: Json | null
          id: string
          name: string
          organization_address: string
          organization_id: string
          processing_count: number
          queued_count: number
          service: Database["public"]["Enums"]["service"]
          status: string
          template: Json
          template_variable_mapping: Json
          updated_at: string
        }
        Insert: {
          accepted_count?: number
          audience_type: Database["public"]["Enums"]["campaign_audience_type"]
          created_at?: string
          created_by?: string | null
          failed_count?: number
          header_media?: Json | null
          id?: string
          name: string
          organization_address: string
          organization_id: string
          processing_count?: number
          queued_count?: number
          service?: Database["public"]["Enums"]["service"]
          status?: string
          template: Json
          template_variable_mapping?: Json
          updated_at?: string
        }
        Update: {
          accepted_count?: number
          audience_type?: Database["public"]["Enums"]["campaign_audience_type"]
          created_at?: string
          created_by?: string | null
          failed_count?: number
          header_media?: Json | null
          id?: string
          name?: string
          organization_address?: string
          organization_id?: string
          processing_count?: number
          queued_count?: number
          service?: Database["public"]["Enums"]["service"]
          status?: string
          template?: Json
          template_variable_mapping?: Json
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "campaigns_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "campaigns_organization_address_fkey"
            columns: ["organization_id", "organization_address"]
            isOneToOne: false
            referencedRelation: "organizations_addresses"
            referencedColumns: ["organization_id", "address"]
          },
          {
            foreignKeyName: "campaigns_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      chatbot_flow_deployments: {
        Row: {
          activated_at: string
          activated_by: string | null
          agent_id: string
          flow_id: string
          flow_version_id: string
          organization_address: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          activated_at?: string
          activated_by?: string | null
          agent_id: string
          flow_id: string
          flow_version_id: string
          organization_address: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          activated_at?: string
          activated_by?: string | null
          agent_id?: string
          flow_id?: string
          flow_version_id?: string
          organization_address?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "chatbot_flow_deployments_activated_by_fkey"
            columns: ["organization_id", "activated_by"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_flow_deployments_address_fkey"
            columns: ["organization_id", "organization_address"]
            isOneToOne: true
            referencedRelation: "organizations_addresses"
            referencedColumns: ["organization_id", "address"]
          },
          {
            foreignKeyName: "chatbot_flow_deployments_agent_fkey"
            columns: ["organization_id", "agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_flow_deployments_flow_fkey"
            columns: ["organization_id", "flow_id"]
            isOneToOne: false
            referencedRelation: "chatbot_flows"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_flow_deployments_version_fkey"
            columns: ["organization_id", "flow_version_id"]
            isOneToOne: false
            referencedRelation: "chatbot_flow_versions"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      chatbot_flow_runs: {
        Row: {
          agent_id: string
          conversation_id: string
          created_at: string
          current_node_id: string | null
          ended_at: string | null
          error: Json | null
          expires_at: string | null
          flow_version_id: string
          id: string
          last_processed_message_id: string | null
          lock_version: number
          organization_id: string
          started_at: string
          status: string
          updated_at: string
          variables: Json
          waiting_for: string | null
        }
        Insert: {
          agent_id: string
          conversation_id: string
          created_at?: string
          current_node_id?: string | null
          ended_at?: string | null
          error?: Json | null
          expires_at?: string | null
          flow_version_id: string
          id?: string
          last_processed_message_id?: string | null
          lock_version?: number
          organization_id: string
          started_at?: string
          status?: string
          updated_at?: string
          variables?: Json
          waiting_for?: string | null
        }
        Update: {
          agent_id?: string
          conversation_id?: string
          created_at?: string
          current_node_id?: string | null
          ended_at?: string | null
          error?: Json | null
          expires_at?: string | null
          flow_version_id?: string
          id?: string
          last_processed_message_id?: string | null
          lock_version?: number
          organization_id?: string
          started_at?: string
          status?: string
          updated_at?: string
          variables?: Json
          waiting_for?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "chatbot_flow_runs_agent_fkey"
            columns: ["organization_id", "agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_flow_runs_conversation_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chatbot_flow_runs_flow_version_fkey"
            columns: ["organization_id", "flow_version_id"]
            isOneToOne: false
            referencedRelation: "chatbot_flow_versions"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_flow_runs_last_processed_message_fkey"
            columns: ["last_processed_message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chatbot_flow_runs_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      chatbot_flow_versions: {
        Row: {
          created_at: string
          created_by: string | null
          definition: Json | null
          editor_graph: Json
          flow_id: string
          id: string
          organization_id: string
          published_at: string | null
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          definition?: Json | null
          editor_graph?: Json
          flow_id: string
          id?: string
          organization_id: string
          published_at?: string | null
          status?: string
          updated_at?: string
          version: number
        }
        Update: {
          created_at?: string
          created_by?: string | null
          definition?: Json | null
          editor_graph?: Json
          flow_id?: string
          id?: string
          organization_id?: string
          published_at?: string | null
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "chatbot_flow_versions_created_by_fkey"
            columns: ["organization_id", "created_by"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_flow_versions_flow_fkey"
            columns: ["organization_id", "flow_id"]
            isOneToOne: false
            referencedRelation: "chatbot_flows"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      chatbot_flows: {
        Row: {
          archived_at: string | null
          created_at: string
          created_by: string | null
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          organization_id: string
          status?: string
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          organization_id?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "chatbot_flows_created_by_fkey"
            columns: ["organization_id", "created_by"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_flows_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      chatbot_integration_raw_events: {
        Row: {
          id: string
          payload_sha256: string
          queue_name: string
          raw_payload: string
          received_at: string
        }
        Insert: {
          id?: string
          payload_sha256: string
          queue_name: string
          raw_payload: string
          received_at?: string
        }
        Update: {
          id?: string
          payload_sha256?: string
          queue_name?: string
          raw_payload?: string
          received_at?: string
        }
        Relationships: []
      }
      chatbot_webhook_credentials: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          name: string
          organization_id: string
          updated_at: string
          vault_secret_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          organization_id: string
          updated_at?: string
          vault_secret_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          organization_id?: string
          updated_at?: string
          vault_secret_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chatbot_webhook_credentials_created_by_fkey"
            columns: ["organization_id", "created_by"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "chatbot_webhook_credentials_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      contacts: {
        Row: {
          city: string | null
          company: string | null
          country: string | null
          created_at: string
          email: string | null
          extra: Json | null
          id: string
          job_title: string | null
          name: string | null
          organization_id: string
          status: string
          updated_at: string
        }
        Insert: {
          city?: string | null
          company?: string | null
          country?: string | null
          created_at?: string
          email?: string | null
          extra?: Json | null
          id?: string
          job_title?: string | null
          name?: string | null
          organization_id: string
          status?: string
          updated_at?: string
        }
        Update: {
          city?: string | null
          company?: string | null
          country?: string | null
          created_at?: string
          email?: string | null
          extra?: Json | null
          id?: string
          job_title?: string | null
          name?: string | null
          organization_id?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "contacts_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      contacts_addresses: {
        Row: {
          address: string
          contact_id: string | null
          created_at: string
          extra: Json | null
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        Insert: {
          address: string
          contact_id?: string | null
          created_at?: string
          extra?: Json | null
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status?: string
          updated_at?: string
        }
        Update: {
          address?: string
          contact_id?: string | null
          created_at?: string
          extra?: Json | null
          organization_id?: string
          service?: Database["public"]["Enums"]["service"]
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "contacts_addresses_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contacts_addresses_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      conversation_assignment_events: {
        Row: {
          actor_agent_id: string | null
          assigned_agent_id: string | null
          assigned_agent_name: string | null
          conversation_id: string
          created_at: string
          id: string
          organization_id: string
          previous_agent_id: string | null
          previous_agent_name: string | null
          routing_queue_id: string | null
          routing_queue_name: string | null
          source: string
          strategy: string
        }
        Insert: {
          actor_agent_id?: string | null
          assigned_agent_id?: string | null
          assigned_agent_name?: string | null
          conversation_id: string
          created_at?: string
          id?: string
          organization_id: string
          previous_agent_id?: string | null
          previous_agent_name?: string | null
          routing_queue_id?: string | null
          routing_queue_name?: string | null
          source: string
          strategy: string
        }
        Update: {
          actor_agent_id?: string | null
          assigned_agent_id?: string | null
          assigned_agent_name?: string | null
          conversation_id?: string
          created_at?: string
          id?: string
          organization_id?: string
          previous_agent_id?: string | null
          previous_agent_name?: string | null
          routing_queue_id?: string | null
          routing_queue_name?: string | null
          source?: string
          strategy?: string
        }
        Relationships: [
          {
            foreignKeyName: "conversation_assignment_event_organization_id_actor_agent__fkey"
            columns: ["organization_id", "actor_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversation_assignment_event_organization_id_assigned_age_fkey"
            columns: ["organization_id", "assigned_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversation_assignment_event_organization_id_conversation_fkey"
            columns: ["organization_id", "conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversation_assignment_event_organization_id_previous_age_fkey"
            columns: ["organization_id", "previous_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversation_assignment_event_organization_id_routing_queu_fkey"
            columns: ["organization_id", "routing_queue_id"]
            isOneToOne: false
            referencedRelation: "routing_queues"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      conversation_routing_events: {
        Row: {
          actor_agent_id: string | null
          conversation_id: string
          created_at: string
          destination_routing_queue_id: string
          destination_routing_queue_name: string
          explanation: string | null
          id: string
          organization_id: string
          previous_routing_queue_id: string | null
          previous_routing_queue_name: string | null
          source: string
        }
        Insert: {
          actor_agent_id?: string | null
          conversation_id: string
          created_at?: string
          destination_routing_queue_id: string
          destination_routing_queue_name: string
          explanation?: string | null
          id?: string
          organization_id: string
          previous_routing_queue_id?: string | null
          previous_routing_queue_name?: string | null
          source: string
        }
        Update: {
          actor_agent_id?: string | null
          conversation_id?: string
          created_at?: string
          destination_routing_queue_id?: string
          destination_routing_queue_name?: string
          explanation?: string | null
          id?: string
          organization_id?: string
          previous_routing_queue_id?: string | null
          previous_routing_queue_name?: string | null
          source?: string
        }
        Relationships: [
          {
            foreignKeyName: "conversation_routing_events_actor_fkey"
            columns: ["actor_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "conversation_routing_events_conversation_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "conversation_routing_events_organization_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      conversations: {
        Row: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        Insert: {
          assigned_agent_id?: string | null
          contact_address?: string | null
          created_at?: string
          extra?: Json | null
          group_address?: string | null
          id?: string
          name?: string | null
          organization_address: string
          organization_id: string
          routed_at?: string | null
          routing_queue_id?: string | null
          service: Database["public"]["Enums"]["service"]
          status?: string
          updated_at?: string
        }
        Update: {
          assigned_agent_id?: string | null
          contact_address?: string | null
          created_at?: string
          extra?: Json | null
          group_address?: string | null
          id?: string
          name?: string | null
          organization_address?: string
          organization_id?: string
          routed_at?: string | null
          routing_queue_id?: string | null
          service?: Database["public"]["Enums"]["service"]
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "conversations_contact_address_fkey"
            columns: ["organization_id", "contact_address"]
            isOneToOne: false
            referencedRelation: "contacts_addresses"
            referencedColumns: ["organization_id", "address"]
          },
          {
            foreignKeyName: "conversations_organization_address_fkey"
            columns: ["organization_id", "organization_address"]
            isOneToOne: false
            referencedRelation: "organizations_addresses"
            referencedColumns: ["organization_id", "address"]
          },
          {
            foreignKeyName: "conversations_organization_id_assigned_agent_id_fkey"
            columns: ["organization_id", "assigned_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversations_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "conversations_organization_id_routing_queue_id_fkey"
            columns: ["organization_id", "routing_queue_id"]
            isOneToOne: false
            referencedRelation: "routing_queues"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      logs: {
        Row: {
          category: string
          created_at: string
          id: string
          level: Database["public"]["Enums"]["log_level"]
          message: string
          metadata: Json | null
          organization_address: string | null
          organization_id: string
          service: Database["public"]["Enums"]["service"] | null
        }
        Insert: {
          category: string
          created_at?: string
          id?: string
          level: Database["public"]["Enums"]["log_level"]
          message: string
          metadata?: Json | null
          organization_address?: string | null
          organization_id: string
          service?: Database["public"]["Enums"]["service"] | null
        }
        Update: {
          category?: string
          created_at?: string
          id?: string
          level?: Database["public"]["Enums"]["log_level"]
          message?: string
          metadata?: Json | null
          organization_address?: string | null
          organization_id?: string
          service?: Database["public"]["Enums"]["service"] | null
        }
        Relationships: [
          {
            foreignKeyName: "logs_organization_address_fkey"
            columns: ["organization_id", "organization_address"]
            isOneToOne: false
            referencedRelation: "organizations_addresses"
            referencedColumns: ["organization_id", "address"]
          },
          {
            foreignKeyName: "logs_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      message_mentions: {
        Row: {
          created_at: string
          mentioned_agent_id: string
          message_id: string
          organization_id: string
        }
        Insert: {
          created_at?: string
          mentioned_agent_id: string
          message_id: string
          organization_id: string
        }
        Update: {
          created_at?: string
          mentioned_agent_id?: string
          message_id?: string
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "message_mentions_agent_fkey"
            columns: ["organization_id", "mentioned_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "message_mentions_message_fkey"
            columns: ["organization_id", "message_id"]
            isOneToOne: false
            referencedRelation: "messages"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      message_templates: {
        Row: {
          category: string
          components: Json
          created_at: string
          created_by: string | null
          external_id: string | null
          id: string
          language: string
          name: string
          organization_address: string
          organization_id: string
          rejection_reason: string | null
          status: string
          submitted_at: string | null
          synced_at: string | null
          updated_at: string
        }
        Insert: {
          category: string
          components?: Json
          created_at?: string
          created_by?: string | null
          external_id?: string | null
          id?: string
          language: string
          name: string
          organization_address: string
          organization_id: string
          rejection_reason?: string | null
          status?: string
          submitted_at?: string | null
          synced_at?: string | null
          updated_at?: string
        }
        Update: {
          category?: string
          components?: Json
          created_at?: string
          created_by?: string | null
          external_id?: string | null
          id?: string
          language?: string
          name?: string
          organization_address?: string
          organization_id?: string
          rejection_reason?: string | null
          status?: string
          submitted_at?: string | null
          synced_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "message_templates_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "message_templates_organization_address_fkey"
            columns: ["organization_id", "organization_address"]
            isOneToOne: false
            referencedRelation: "organizations_addresses"
            referencedColumns: ["organization_id", "address"]
          },
          {
            foreignKeyName: "message_templates_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      messages: {
        Row: {
          agent_id: string | null
          contact_address: string | null
          content: Json
          conversation_id: string
          created_at: string
          direction: Database["public"]["Enums"]["direction"]
          external_id: string | null
          group_address: string | null
          id: string
          organization_address: string
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status: Json
          thread_id: string | null
          timestamp: string
          updated_at: string
        }
        Insert: {
          agent_id?: string | null
          contact_address?: string | null
          content: Json
          conversation_id: string
          created_at?: string
          direction: Database["public"]["Enums"]["direction"]
          external_id?: string | null
          group_address?: string | null
          id?: string
          organization_address: string
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status?: Json
          thread_id?: string | null
          timestamp?: string
          updated_at?: string
        }
        Update: {
          agent_id?: string | null
          contact_address?: string | null
          content?: Json
          conversation_id?: string
          created_at?: string
          direction?: Database["public"]["Enums"]["direction"]
          external_id?: string | null
          group_address?: string | null
          id?: string
          organization_address?: string
          organization_id?: string
          service?: Database["public"]["Enums"]["service"]
          status?: Json
          thread_id?: string | null
          timestamp?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "messages_agent_id_fkey"
            columns: ["agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "messages_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      onboarding_tokens: {
        Row: {
          callback_url: string | null
          created_at: string
          expires_at: string
          id: string
          name: string
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status: string
          used_at: string | null
          verify_token: string | null
        }
        Insert: {
          callback_url?: string | null
          created_at?: string
          expires_at: string
          id?: string
          name: string
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status?: string
          used_at?: string | null
          verify_token?: string | null
        }
        Update: {
          callback_url?: string | null
          created_at?: string
          expires_at?: string
          id?: string
          name?: string
          organization_id?: string
          service?: Database["public"]["Enums"]["service"]
          status?: string
          used_at?: string | null
          verify_token?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "onboarding_tokens_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_agent_capacity: {
        Row: {
          created_at: string
          max_agent_seats: number | null
          organization_id: string
          updated_at: string
          updated_by: string | null
          updated_by_scope: string
        }
        Insert: {
          created_at?: string
          max_agent_seats?: number | null
          organization_id: string
          updated_at?: string
          updated_by?: string | null
          updated_by_scope?: string
        }
        Update: {
          created_at?: string
          max_agent_seats?: number | null
          organization_id?: string
          updated_at?: string
          updated_by?: string | null
          updated_by_scope?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_agent_capacity_organization_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_automation_settings: {
        Row: {
          auto_assign_conversations: boolean
          auto_save_whatsapp_contacts: boolean
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        Insert: {
          auto_assign_conversations?: boolean
          auto_save_whatsapp_contacts?: boolean
          organization_id: string
          updated_at?: string
          updated_by_scope?: string
          updated_by_user_id?: string | null
        }
        Update: {
          auto_assign_conversations?: boolean
          auto_save_whatsapp_contacts?: boolean
          organization_id?: string
          updated_at?: string
          updated_by_scope?: string
          updated_by_user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "organization_automation_settings_organization_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_media_storage: {
        Row: {
          created_at: string
          last_reconciled_at: string | null
          object_count: number
          organization_id: string
          quota_bytes: number
          updated_at: string
          updated_by: string | null
          updated_by_scope: string
          used_bytes: number
        }
        Insert: {
          created_at?: string
          last_reconciled_at?: string | null
          object_count?: number
          organization_id: string
          quota_bytes?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_scope?: string
          used_bytes?: number
        }
        Update: {
          created_at?: string
          last_reconciled_at?: string | null
          object_count?: number
          organization_id?: string
          quota_bytes?: number
          updated_at?: string
          updated_by?: string | null
          updated_by_scope?: string
          used_bytes?: number
        }
        Relationships: [
          {
            foreignKeyName: "organization_media_storage_organization_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_ui_settings: {
        Row: {
          chat_bubble_theme: string
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        Insert: {
          chat_bubble_theme?: string
          organization_id: string
          updated_at?: string
          updated_by_scope?: string
          updated_by_user_id?: string | null
        }
        Update: {
          chat_bubble_theme?: string
          organization_id?: string
          updated_at?: string
          updated_by_scope?: string
          updated_by_user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "organization_ui_settings_organization_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string
          extra: Json | null
          id: string
          name: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          extra?: Json | null
          id?: string
          name: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          extra?: Json | null
          id?: string
          name?: string
          updated_at?: string
        }
        Relationships: []
      }
      organizations_addresses: {
        Row: {
          address: string
          created_at: string
          extra: Json | null
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        Insert: {
          address: string
          created_at?: string
          extra?: Json | null
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status?: string
          updated_at?: string
        }
        Update: {
          address?: string
          created_at?: string
          extra?: Json | null
          organization_id?: string
          service?: Database["public"]["Enums"]["service"]
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "organizations_addresses_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      platform_admin_access_events: {
        Row: {
          accessed_at: string
          id: string
          organization_id: string | null
          platform_admin_user_id: string
          request_id: string
          scope: string
        }
        Insert: {
          accessed_at?: string
          id?: string
          organization_id?: string | null
          platform_admin_user_id: string
          request_id: string
          scope: string
        }
        Update: {
          accessed_at?: string
          id?: string
          organization_id?: string | null
          platform_admin_user_id?: string
          request_id?: string
          scope?: string
        }
        Relationships: [
          {
            foreignKeyName: "platform_admin_access_events_admin_fkey"
            columns: ["platform_admin_user_id"]
            isOneToOne: false
            referencedRelation: "platform_admins"
            referencedColumns: ["user_id"]
          },
        ]
      }
      platform_admin_action_events: {
        Row: {
          action_type: string
          after_state: Json
          before_state: Json | null
          created_at: string
          id: string
          organization_id: string
          platform_admin_user_id: string
          request_id: string
          target_id: string
          target_type: string
        }
        Insert: {
          action_type: string
          after_state: Json
          before_state?: Json | null
          created_at?: string
          id?: string
          organization_id: string
          platform_admin_user_id: string
          request_id: string
          target_id: string
          target_type: string
        }
        Update: {
          action_type?: string
          after_state?: Json
          before_state?: Json | null
          created_at?: string
          id?: string
          organization_id?: string
          platform_admin_user_id?: string
          request_id?: string
          target_id?: string
          target_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "platform_admin_action_events_admin_fkey"
            columns: ["platform_admin_user_id"]
            isOneToOne: false
            referencedRelation: "platform_admins"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "platform_admin_action_events_organization_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      platform_admins: {
        Row: {
          active: boolean
          created_at: string
          created_by: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          created_by?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          created_by?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      platform_report_export_events: {
        Row: {
          generated_at: string
          id: string
          organization_id: string
          platform_admin_user_id: string
          report_month: string
          report_type: string
          request_id: string
          row_count: number
        }
        Insert: {
          generated_at?: string
          id?: string
          organization_id: string
          platform_admin_user_id: string
          report_month: string
          report_type: string
          request_id: string
          row_count: number
        }
        Update: {
          generated_at?: string
          id?: string
          organization_id?: string
          platform_admin_user_id?: string
          report_month?: string
          report_type?: string
          request_id?: string
          row_count?: number
        }
        Relationships: [
          {
            foreignKeyName: "platform_report_export_events_admin_fkey"
            columns: ["platform_admin_user_id"]
            isOneToOne: false
            referencedRelation: "platform_admins"
            referencedColumns: ["user_id"]
          },
        ]
      }
      quick_replies: {
        Row: {
          content: string
          created_at: string
          id: string
          organization_id: string
          shortcut: string
          updated_at: string
        }
        Insert: {
          content: string
          created_at?: string
          id?: string
          organization_id: string
          shortcut: string
          updated_at?: string
        }
        Update: {
          content?: string
          created_at?: string
          id?: string
          organization_id?: string
          shortcut?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "quick_replies_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      routing_queue_assignment_state: {
        Row: {
          last_assigned_agent_id: string | null
          organization_id: string
          routing_queue_id: string
          updated_at: string
        }
        Insert: {
          last_assigned_agent_id?: string | null
          organization_id: string
          routing_queue_id: string
          updated_at?: string
        }
        Update: {
          last_assigned_agent_id?: string | null
          organization_id?: string
          routing_queue_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "routing_queue_assignment_stat_organization_id_last_assigne_fkey"
            columns: ["organization_id", "last_assigned_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "routing_queue_assignment_stat_organization_id_routing_queu_fkey"
            columns: ["organization_id", "routing_queue_id"]
            isOneToOne: true
            referencedRelation: "routing_queues"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      routing_queue_members: {
        Row: {
          agent_id: string
          created_at: string
          organization_id: string
          routing_queue_id: string
        }
        Insert: {
          agent_id: string
          created_at?: string
          organization_id: string
          routing_queue_id: string
        }
        Update: {
          agent_id?: string
          created_at?: string
          organization_id?: string
          routing_queue_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "routing_queue_members_agent_fkey"
            columns: ["organization_id", "agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "routing_queue_members_queue_fkey"
            columns: ["organization_id", "routing_queue_id"]
            isOneToOne: false
            referencedRelation: "routing_queues"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      routing_queues: {
        Row: {
          assignment_strategy: string
          created_at: string
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        Insert: {
          assignment_strategy?: string
          created_at?: string
          id?: string
          name: string
          organization_id: string
          status?: string
          updated_at?: string
        }
        Update: {
          assignment_strategy?: string
          created_at?: string
          id?: string
          name?: string
          organization_id?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "routing_queues_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      user_notifications: {
        Row: {
          actor_agent_id: string | null
          conversation_id: string | null
          created_at: string
          id: string
          notification_type: string
          organization_id: string
          payload: Json
          read_at: string | null
          recipient_agent_id: string
          resolved_at: string | null
          source_event_key: string
        }
        Insert: {
          actor_agent_id?: string | null
          conversation_id?: string | null
          created_at?: string
          id?: string
          notification_type: string
          organization_id: string
          payload?: Json
          read_at?: string | null
          recipient_agent_id: string
          resolved_at?: string | null
          source_event_key: string
        }
        Update: {
          actor_agent_id?: string | null
          conversation_id?: string | null
          created_at?: string
          id?: string
          notification_type?: string
          organization_id?: string
          payload?: Json
          read_at?: string | null
          recipient_agent_id?: string
          resolved_at?: string | null
          source_event_key?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_notifications_actor_agent_fkey"
            columns: ["organization_id", "actor_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "user_notifications_conversation_fkey"
            columns: ["organization_id", "conversation_id"]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "user_notifications_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_notifications_recipient_agent_fkey"
            columns: ["organization_id", "recipient_agent_id"]
            isOneToOne: false
            referencedRelation: "agents"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      webhooks: {
        Row: {
          created_at: string
          id: string
          operations: Database["public"]["Enums"]["webhook_operation"][]
          organization_id: string
          table_name: Database["public"]["Enums"]["webhook_table"]
          token: string | null
          updated_at: string
          url: string
        }
        Insert: {
          created_at?: string
          id?: string
          operations: Database["public"]["Enums"]["webhook_operation"][]
          organization_id: string
          table_name: Database["public"]["Enums"]["webhook_table"]
          token?: string | null
          updated_at?: string
          url: string
        }
        Update: {
          created_at?: string
          id?: string
          operations?: Database["public"]["Enums"]["webhook_operation"][]
          organization_id?: string
          table_name?: Database["public"]["Enums"]["webhook_table"]
          token?: string | null
          updated_at?: string
          url?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhooks_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      whatsapp_integration_health: {
        Row: {
          created_at: string
          failure_code: string | null
          failure_message: string | null
          last_check_attempted_at: string | null
          last_check_succeeded_at: string | null
          last_webhook_error_at: string | null
          last_webhook_received_at: string | null
          last_webhook_succeeded_at: string | null
          organization_id: string
          phone_number_id: string
          token_expires_at: string | null
          token_status: string
          token_validated_at: string | null
          updated_at: string
          webhook_subscription_status: string
          webhook_validated_at: string | null
        }
        Insert: {
          created_at?: string
          failure_code?: string | null
          failure_message?: string | null
          last_check_attempted_at?: string | null
          last_check_succeeded_at?: string | null
          last_webhook_error_at?: string | null
          last_webhook_received_at?: string | null
          last_webhook_succeeded_at?: string | null
          organization_id: string
          phone_number_id: string
          token_expires_at?: string | null
          token_status?: string
          token_validated_at?: string | null
          updated_at?: string
          webhook_subscription_status?: string
          webhook_validated_at?: string | null
        }
        Update: {
          created_at?: string
          failure_code?: string | null
          failure_message?: string | null
          last_check_attempted_at?: string | null
          last_check_succeeded_at?: string | null
          last_webhook_error_at?: string | null
          last_webhook_received_at?: string | null
          last_webhook_succeeded_at?: string | null
          organization_id?: string
          phone_number_id?: string
          token_expires_at?: string | null
          token_status?: string
          token_validated_at?: string | null
          updated_at?: string
          webhook_subscription_status?: string
          webhook_validated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "whatsapp_integration_health_account_fkey"
            columns: ["organization_id", "phone_number_id"]
            isOneToOne: true
            referencedRelation: "organizations_addresses"
            referencedColumns: ["organization_id", "address"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      agent_can_download_media_object: {
        Args: { p_name: string }
        Returns: boolean
      }
      agent_can_read_conversation: {
        Args: { p_conversation_id: string; p_organization_id: string }
        Returns: boolean
      }
      agent_conversation_update_rules: {
        Args: {
          p_assigned_agent_id: string
          p_contact_address: string
          p_group_address: string
          p_id: string
          p_organization_address: string
          p_organization_id: string
          p_routed_at: string
          p_routing_queue_id: string
          p_service: Database["public"]["Enums"]["service"]
        }
        Returns: boolean
      }
      agent_message_insert_rules: {
        Args: {
          p_agent_id: string
          p_conversation_id: string
          p_direction: Database["public"]["Enums"]["direction"]
          p_group_address: string
          p_organization_address: string
          p_organization_id: string
          p_service: Database["public"]["Enums"]["service"]
        }
        Returns: boolean
      }
      agent_owns_conversation: {
        Args: { p_conversation_id: string; p_organization_id: string }
        Returns: boolean
      }
      agent_update_by_owner_rules: {
        Args: {
          p_ai: boolean
          p_extra: Json
          p_id: string
          p_organization_id: string
          p_user_id: string
        }
        Returns: boolean
      }
      assign_conversation_to_me: {
        Args: { p_conversation_id: string }
        Returns: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      claim_campaign_deliveries: {
        Args: { p_limit?: number }
        Returns: {
          attempts: number
          campaign_id: string
          contact_address: string
          contact_name: string
          delivery_id: string
          header_media: Json
          organization_address: string
          organization_id: string
          template: Json
          template_variable_mapping: Json
          variables: Json
        }[]
      }
      commit_chatbot_flow_execution: {
        Args: {
          p_current_node_id: string
          p_error: Json
          p_expected_lock_version: number
          p_handoff_agent_id?: string
          p_handoff_routing_queue_id?: string
          p_message_id: string
          p_outgoing_messages?: Json
          p_outgoing_texts: string[]
          p_run_id: string
          p_status: string
          p_variables: Json
          p_waiting_for: string
        }
        Returns: {
          message_ids: string[]
          outcome: string
          run_lock_version: number
        }[]
      }
      contact_address_update_rules: {
        Args: {
          p_address: string
          p_extra: Json
          p_organization_id: string
          p_service: Database["public"]["Enums"]["service"]
          p_status: string
        }
        Returns: boolean
      }
      count_organization_agent_seats: {
        Args: { p_organization_id: string }
        Returns: number
      }
      create_chatbot_flow_draft: {
        Args: {
          p_created_by?: string
          p_name: string
          p_organization_id: string
        }
        Returns: {
          draft_id: string
          draft_updated_at: string
          draft_version: number
          flow_id: string
        }[]
      }
      create_chatbot_webhook_credential: {
        Args: {
          p_created_by?: string
          p_headers: Json
          p_name: string
          p_organization_id: string
        }
        Returns: {
          created_at: string
          id: string
          name: string
          updated_at: string
        }[]
      }
      create_conversation_for_me: {
        Args: {
          p_contact_address?: string
          p_extra?: Json
          p_group_address?: string
          p_name?: string
          p_organization_address: string
          p_organization_id: string
          p_service: Database["public"]["Enums"]["service"]
        }
        Returns: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_platform_organization_agent_invitation: {
        Args: {
          p_email: string
          p_name: string
          p_organization_id: string
          p_request_id: string
        }
        Returns: {
          ai: boolean
          created_at: string
          extra: Json | null
          id: string
          name: string
          organization_id: string
          picture: string | null
          updated_at: string
          user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "agents"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_platform_routing_queue: {
        Args: {
          p_agent_ids?: string[]
          p_name: string
          p_organization_id: string
          p_request_id?: string
        }
        Returns: {
          assignment_strategy: string
          created_at: string
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "routing_queues"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_private_note: {
        Args: {
          p_conversation_id: string
          p_mentioned_agent_ids?: string[]
          p_text: string
        }
        Returns: {
          agent_id: string | null
          contact_address: string | null
          content: Json
          conversation_id: string
          created_at: string
          direction: Database["public"]["Enums"]["direction"]
          external_id: string | null
          group_address: string | null
          id: string
          organization_address: string
          organization_id: string
          service: Database["public"]["Enums"]["service"]
          status: Json
          thread_id: string | null
          timestamp: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "messages"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_quick_reply: {
        Args: {
          p_content: string
          p_organization_id: string
          p_shortcut: string
        }
        Returns: {
          content: string
          created_at: string
          id: string
          organization_id: string
          shortcut: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "quick_replies"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_routing_queue: {
        Args: {
          p_agent_ids?: string[]
          p_name: string
          p_organization_id: string
        }
        Returns: {
          assignment_strategy: string
          created_at: string
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "routing_queues"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      delete_quick_reply: {
        Args: { p_quick_reply_id: string }
        Returns: string
      }
      duplicate_chatbot_flow_draft: {
        Args: {
          p_created_by?: string
          p_name: string
          p_organization_id: string
          p_source_flow_id: string
        }
        Returns: {
          draft_id: string
          draft_updated_at: string
          draft_version: number
          flow_id: string
        }[]
      }
      enqueue_user_notification: {
        Args: {
          p_actor_agent_id: string
          p_conversation_id: string
          p_notification_type: string
          p_organization_id: string
          p_payload?: Json
          p_recipient_agent_id: string
          p_source_event_key: string
        }
        Returns: string
      }
      ensure_chatbot_runtime_agent: {
        Args: { p_organization_id: string }
        Returns: string
      }
      ensure_external_chatbot_agent: {
        Args: {
          p_integration_key: string
          p_name: string
          p_organization_id: string
        }
        Returns: string
      }
      get_authorized_orgs: {
        Args: { role?: Database["public"]["Enums"]["role"] }
        Returns: string[]
      }
      get_authorized_orgs_by_roles: {
        Args: { roles: Database["public"]["Enums"]["role"][] }
        Returns: string[]
      }
      get_campaign_audience_count: {
        Args: { p_campaign_id: string; p_organization_id: string }
        Returns: number
      }
      get_campaign_audience_preview: {
        Args: {
          p_campaign_id: string
          p_limit?: number
          p_organization_id: string
        }
        Returns: {
          contact_address: string
          name: string
          variables: Json
        }[]
      }
      get_conversation_queue_conversations: {
        Args: {
          p_limit?: number
          p_offset?: number
          p_organization_id: string
          p_queue_key: string
          p_routing_queue_id?: string
        }
        Returns: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }[]
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      get_conversation_queues: {
        Args: { p_organization_id?: string }
        Returns: {
          enabled: boolean
          key: string
          label: string
          order: number
        }[]
      }
      get_current_human_agent_id: {
        Args: { p_organization_id: string }
        Returns: string
      }
      get_dashboard_metrics: {
        Args: { p_days?: number; p_organization_id: string }
        Returns: {
          active_last_30_days: number
          active_last_7_days: number
          active_today: number
          closed_conversations: number
          contact_activity: Json
          message_activity: Json
          new_contacts: number
          open_conversations: number
          period_end: string
          period_start: string
          team_snapshot: Json
          total_contacts: number
          unassigned_conversations: number
        }[]
      }
      get_my_assignment_availability: {
        Args: { p_organization_id: string }
        Returns: {
          available: boolean
          eligible: boolean
          last_heartbeat_at: string
          updated_at: string
        }[]
      }
      get_organization_automation_settings: {
        Args: { p_organization_id: string }
        Returns: {
          auto_assign_conversations: boolean
          auto_save_whatsapp_contacts: boolean
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_automation_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      get_organization_media_storage: {
        Args: { p_organization_id: string }
        Returns: {
          last_reconciled_at: string
          object_count: number
          organization_id: string
          quota_bytes: number
          remaining_bytes: number
          storage_status: string
          updated_at: string
          usage_percent: number
          used_bytes: number
        }[]
      }
      get_organization_ui_settings: {
        Args: { p_organization_id: string }
        Returns: {
          chat_bubble_theme: string
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_ui_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      get_platform_organization_agent_audit_state: {
        Args: { p_agent_id: string }
        Returns: Json
      }
      get_platform_organization_agent_capacity: {
        Args: { p_organization_id: string }
        Returns: {
          max_agent_seats: number
          organization_id: string
          over_limit: boolean
          updated_at: string
          used_agent_seats: number
        }[]
      }
      get_platform_organization_automation_settings: {
        Args: { p_organization_id: string }
        Returns: {
          auto_assign_conversations: boolean
          auto_save_whatsapp_contacts: boolean
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_automation_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      get_platform_organization_media_storage: {
        Args: { p_organization_id: string }
        Returns: {
          last_reconciled_at: string
          object_count: number
          organization_id: string
          organization_name: string
          quota_bytes: number
          remaining_bytes: number
          storage_status: string
          updated_at: string
          usage_percent: number
          used_bytes: number
        }[]
      }
      get_platform_overview: {
        Args: never
        Returns: {
          active_contact_count: number
          active_conversation_count: number
          connected_instagram_account_count: number
          connected_whatsapp_account_count: number
          human_member_count: number
          organization_count: number
        }[]
      }
      get_platform_tenant_summary: {
        Args: { p_organization_id: string }
        Returns: {
          accepted_agent_count: number
          active_contact_count: number
          active_conversation_count: number
          connected_instagram_account_count: number
          connected_whatsapp_account_count: number
          human_member_count: number
          organization_created_at: string
          organization_id: string
          organization_name: string
          organization_updated_at: string
          plan_id: string
          tier_id: string
          tier_name: string
        }[]
      }
      get_platform_whatsapp_action_result: {
        Args: {
          p_action_type: string
          p_organization_id: string
          p_phone_number_id: string
          p_request_id: string
        }
        Returns: Json
      }
      get_platform_whatsapp_health: {
        Args: { p_organization_id: string; p_phone_number_id: string }
        Returns: {
          application_id: string
          business_id: string
          connection_status: string
          display_name: string
          display_phone: string
          failure_code: string
          failure_message: string
          health_status: string
          last_check_attempted_at: string
          last_check_succeeded_at: string
          last_incoming_message_at: string
          last_message_activity_at: string
          last_outgoing_message_at: string
          last_webhook_error_at: string
          last_webhook_received_at: string
          last_webhook_succeeded_at: string
          messaging_limit_tier: string
          organization_id: string
          phone_number_id: string
          phone_number_status: string
          profile_synced_at: string
          quality_rating: string
          template_status_summary: Json
          token_expires_at: string
          token_status: string
          token_validated_at: string
          total_count: number
          waba_id: string
          webhook_error_count_24h: number
          webhook_status: string
          webhook_validated_at: string
        }[]
      }
      get_request_organization_role: {
        Args: { p_organization_id: string }
        Returns: Database["public"]["Enums"]["role"]
      }
      get_routing_queue_audit_state: {
        Args: { p_routing_queue_id: string }
        Returns: Json
      }
      get_unread_notification_count: {
        Args: { p_organization_id: string }
        Returns: number
      }
      heartbeat_my_assignment_availability: {
        Args: { p_organization_id: string }
        Returns: {
          available: boolean
          eligible: boolean
          last_heartbeat_at: string
          updated_at: string
        }[]
      }
      init_data: {
        Args: {
          p_limit?: number
          p_organization_id: string
          p_per_conversation?: number
          p_since?: string
          p_until?: string
        }
        Returns: Json
      }
      is_counted_agent_seat: {
        Args: { p_ai: boolean; p_extra: Json }
        Returns: boolean
      }
      is_platform_admin: { Args: never; Returns: boolean }
      is_whatsapp_contact_auto_save_enabled: {
        Args: { p_organization_id: string }
        Returns: boolean
      }
      list_campaigns_page: {
        Args: {
          p_audience_type?: Database["public"]["Enums"]["campaign_audience_type"]
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_readiness?: string
          p_search?: string
        }
        Returns: {
          accepted_count: number
          audience_count: number
          audience_type: Database["public"]["Enums"]["campaign_audience_type"]
          created_at: string
          created_by: string
          failed_count: number
          header_media: Json
          id: string
          name: string
          organization_address: string
          organization_id: string
          processing_count: number
          queued_count: number
          readiness: string
          service: Database["public"]["Enums"]["service"]
          status: string
          template: Json
          template_variable_mapping: Json
          total_count: number
          updated_at: string
        }[]
      }
      list_chatbot_flows_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
          p_status?: string
        }
        Returns: {
          created_at: string
          created_by: string
          created_by_name: string
          draft_id: string
          draft_updated_at: string
          draft_version: number
          has_unpublished_changes: boolean
          id: string
          name: string
          organization_id: string
          published_at: string
          published_version: number
          published_version_id: string
          status: string
          total_count: number
          updated_at: string
        }[]
      }
      list_contacts_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
        }
        Returns: {
          addresses: Json
          city: string
          company: string
          country: string
          created_at: string
          email: string
          id: string
          job_title: string
          name: string
          organization_id: string
          status: string
          total_count: number
          updated_at: string
        }[]
      }
      list_members_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_role?: Database["public"]["Enums"]["role"]
          p_search?: string
          p_status?: string
        }
        Returns: {
          created_at: string
          email: string
          id: string
          is_last_owner: boolean
          name: string
          organization_id: string
          picture: string
          role: Database["public"]["Enums"]["role"]
          status: string
          total_count: number
          updated_at: string
          user_id: string
        }[]
      }
      list_mentionable_humans_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
        }
        Returns: {
          id: string
          name: string
          picture: string
          role: Database["public"]["Enums"]["role"]
          total_count: number
        }[]
      }
      list_mentioned_conversations_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
        }
        Returns: {
          assigned_agent_id: string
          contact_address: string
          created_at: string
          extra: Json
          group_address: string
          id: string
          latest_mention_at: string
          name: string
          organization_address: string
          organization_id: string
          preview_message: Json
          routed_at: string
          routing_queue_id: string
          service: Database["public"]["Enums"]["service"]
          status: string
          total_count: number
          updated_at: string
        }[]
      }
      list_message_templates_page: {
        Args: {
          p_category?: string
          p_organization_address?: string
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
          p_status?: string
        }
        Returns: {
          category: string
          components: Json
          created_at: string
          created_by: string
          external_id: string
          id: string
          language: string
          name: string
          organization_address: string
          organization_id: string
          rejection_reason: string
          status: string
          submitted_at: string
          synced_at: string
          total_count: number
          updated_at: string
        }[]
      }
      list_platform_campaign_report_rows: {
        Args: {
          p_month: string
          p_organization_id: string
          p_page?: number
          p_page_size?: number
        }
        Returns: {
          accepted_count: number
          audience_type: Database["public"]["Enums"]["campaign_audience_type"]
          campaign_id: string
          campaign_name: string
          campaign_status: string
          created_by_agent_id: string
          created_by_agent_name: string
          failed_count: number
          last_updated_at_utc: string
          launched_at_utc: string
          organization_address: string
          organization_id: string
          organization_name: string
          period_end_utc: string
          period_start_utc: string
          processing_count: number
          queued_count: number
          report_month: string
          template_language: string
          template_name: string
          total_count: number
          total_recipient_count: number
        }[]
      }
      list_platform_conversation_report_rows: {
        Args: {
          p_month: string
          p_organization_id: string
          p_page?: number
          p_page_size?: number
        }
        Returns: {
          assigned_agent_id: string
          assigned_agent_name: string
          contact_address: string
          contact_id: string
          conversation_created_at: string
          conversation_id: string
          conversation_status: string
          customer_name: string
          first_activity_at_utc: string
          incoming_message_count: number
          last_activity_at_utc: string
          organization_address: string
          organization_id: string
          organization_name: string
          outgoing_message_count: number
          period_end_utc: string
          period_start_utc: string
          report_month: string
          service: Database["public"]["Enums"]["service"]
          total_count: number
          total_message_count: number
        }[]
      }
      list_platform_media_storage_page: {
        Args: {
          p_page?: number
          p_page_size?: number
          p_search?: string
          p_status?: string
        }
        Returns: {
          last_reconciled_at: string
          object_count: number
          organization_id: string
          organization_name: string
          quota_bytes: number
          remaining_bytes: number
          storage_status: string
          total_count: number
          updated_at: string
          usage_percent: number
          used_bytes: number
        }[]
      }
      list_platform_organization_agents_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
        }
        Returns: {
          created_at: string
          email: string
          id: string
          invitation_status: string
          name: string
          organization_id: string
          picture: string
          queue_ids: string[]
          queue_names: string[]
          total_count: number
          user_id: string
        }[]
      }
      list_platform_organizations_page: {
        Args: { p_page?: number; p_page_size?: number; p_search?: string }
        Returns: {
          active_contact_count: number
          active_conversation_count: number
          connected_instagram_account_count: number
          connected_whatsapp_account_count: number
          human_member_count: number
          organization_created_at: string
          organization_id: string
          organization_name: string
          organization_updated_at: string
          plan_id: string
          tier_id: string
          tier_name: string
          total_count: number
        }[]
      }
      list_platform_routing_queues_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
          p_status?: string
        }
        Returns: {
          assignment_strategy: string
          created_at: string
          eligible_member_count: number
          id: string
          member_count: number
          member_ids: string[]
          member_names: string[]
          member_pictures: string[]
          name: string
          organization_id: string
          status: string
          total_count: number
          updated_at: string
        }[]
      }
      list_platform_whatsapp_health_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
          p_status?: string
        }
        Returns: {
          application_id: string
          business_id: string
          connection_status: string
          display_name: string
          display_phone: string
          failure_code: string
          failure_message: string
          health_status: string
          last_check_attempted_at: string
          last_check_succeeded_at: string
          last_incoming_message_at: string
          last_message_activity_at: string
          last_outgoing_message_at: string
          last_webhook_error_at: string
          last_webhook_received_at: string
          last_webhook_succeeded_at: string
          messaging_limit_tier: string
          organization_id: string
          phone_number_id: string
          phone_number_status: string
          profile_synced_at: string
          quality_rating: string
          template_status_summary: Json
          token_expires_at: string
          token_status: string
          token_validated_at: string
          total_count: number
          waba_id: string
          webhook_error_count_24h: number
          webhook_status: string
          webhook_validated_at: string
        }[]
      }
      list_quick_replies_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
        }
        Returns: {
          content: string
          created_at: string
          id: string
          organization_id: string
          shortcut: string
          total_count: number
          updated_at: string
        }[]
      }
      list_routing_queue_options: {
        Args: { p_organization_id: string }
        Returns: {
          id: string
          name: string
        }[]
      }
      list_routing_queues_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_search?: string
        }
        Returns: {
          assignment_strategy: string
          created_at: string
          eligible_member_count: number
          id: string
          member_count: number
          member_ids: string[]
          name: string
          organization_id: string
          status: string
          total_count: number
          updated_at: string
        }[]
      }
      list_transferable_routing_queue_options: {
        Args: { p_conversation_id: string }
        Returns: {
          id: string
          name: string
        }[]
      }
      list_user_notifications_page: {
        Args: {
          p_organization_id: string
          p_page?: number
          p_page_size?: number
          p_unread_only?: boolean
        }
        Returns: {
          actor_agent_id: string
          conversation_id: string
          created_at: string
          id: string
          notification_type: string
          organization_id: string
          payload: Json
          read_at: string
          recipient_agent_id: string
          resolved_at: string
          source_event_key: string
          total_count: number
        }[]
      }
      mark_all_user_notifications_read: {
        Args: { p_organization_id: string }
        Returns: number
      }
      mark_user_notification_read: {
        Args: { p_notification_id: string }
        Returns: {
          actor_agent_id: string | null
          conversation_id: string | null
          created_at: string
          id: string
          notification_type: string
          organization_id: string
          payload: Json
          read_at: string | null
          recipient_agent_id: string
          resolved_at: string | null
          source_event_key: string
        }
        SetofOptions: {
          from: "*"
          to: "user_notifications"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      media_storage_object_size_bytes: {
        Args: { p_metadata: Json }
        Returns: number
      }
      media_storage_path_organization_id: {
        Args: { p_bucket_id: string; p_name: string }
        Returns: string
      }
      media_storage_status: {
        Args: { p_quota_bytes: number; p_used_bytes: number }
        Returns: string
      }
      member_self_update_rules: {
        Args: {
          p_ai: boolean
          p_extra: Json
          p_id: string
          p_organization_id: string
          p_user_id: string
        }
        Returns: boolean
      }
      member_update_by_supervisor_rules: {
        Args: {
          p_ai: boolean
          p_extra: Json
          p_id: string
          p_organization_id: string
          p_user_id: string
        }
        Returns: boolean
      }
      merge_update_jsonb: {
        Args: { object: Json; path: string[]; target: Json }
        Returns: Json
      }
      normalize_quick_reply_shortcut: {
        Args: { p_shortcut: string }
        Returns: string
      }
      org_update_by_admin_rules: {
        Args: { p_id: string; p_name: string }
        Returns: boolean
      }
      platform_whatsapp_health_state: {
        Args: {
          p_connection_status: string
          p_failure_code: string
          p_last_check_attempted_at: string
          p_last_check_succeeded_at: string
          p_last_webhook_error_at: string
          p_quality_rating: string
          p_token_expires_at: string
          p_token_status: string
          p_webhook_status: string
        }
        Returns: string
      }
      prepare_chatbot_flow_execution: {
        Args: {
          p_agent_id?: string
          p_flow_version_id?: string
          p_message_id: string
        }
        Returns: {
          flow_definition: Json
          outcome: string
          run_current_node_id: string
          run_id: string
          run_is_new: boolean
          run_lock_version: number
          run_status: string
          run_variables: Json
          run_waiting_for: string
        }[]
      }
      process_auto_assignment_backlog: {
        Args: {
          p_limit?: number
          p_organization_id?: string
          p_routing_queue_id?: string
          p_source?: string
        }
        Returns: number
      }
      publish_chatbot_flow_draft: {
        Args: {
          p_created_by?: string
          p_definition: Json
          p_expected_updated_at: string
          p_flow_id: string
          p_organization_id: string
          p_version_id: string
        }
        Returns: {
          draft_id: string
          draft_updated_at: string
          draft_version: number
          outcome: string
          published_version: number
          published_version_id: string
        }[]
      }
      reconcile_organization_media_storage_batch: {
        Args: { p_limit?: number }
        Returns: number
      }
      reconcile_organization_media_storage_internal: {
        Args: { p_organization_id: string }
        Returns: undefined
      }
      reconcile_platform_organization_media_storage: {
        Args: { p_organization_id: string; p_request_id: string }
        Returns: {
          last_reconciled_at: string
          object_count: number
          organization_id: string
          organization_name: string
          quota_bytes: number
          remaining_bytes: number
          storage_status: string
          updated_at: string
          usage_percent: number
          used_bytes: number
        }[]
      }
      record_campaign_delivery_result: {
        Args: {
          p_delivery_id: string
          p_error?: Json
          p_external_id?: string
          p_retryable?: boolean
        }
        Returns: string
      }
      record_external_chatbot_reply: {
        Args: {
          p_agent_id: string
          p_content: Json
          p_organization_id: string
          p_phone_number_id: string
          p_recipient: string
          p_sent_at: string
          p_wamid: string
        }
        Returns: {
          message_id: string
          outcome: string
        }[]
      }
      record_platform_access: {
        Args: {
          p_organization_id?: string
          p_request_id?: string
          p_scope?: string
        }
        Returns: string
      }
      record_platform_report_export: {
        Args: {
          p_month: string
          p_organization_id: string
          p_report_type: string
          p_request_id: string
          p_row_count: number
        }
        Returns: string
      }
      record_platform_whatsapp_action: {
        Args: {
          p_action_type: string
          p_after_state: Json
          p_organization_id: string
          p_phone_number_id: string
          p_request_id: string
        }
        Returns: string
      }
      remove_platform_organization_agent: {
        Args: { p_agent_id: string; p_request_id: string }
        Returns: boolean
      }
      replace_routing_queue_members: {
        Args: {
          p_agent_ids: string[]
          p_organization_id: string
          p_routing_queue_id: string
        }
        Returns: undefined
      }
      require_platform_admin: { Args: never; Returns: string }
      resolve_chatbot_webhook_credential: {
        Args: { p_credential_id: string; p_organization_id: string }
        Returns: Json
      }
      role_rank: {
        Args: { role: Database["public"]["Enums"]["role"] }
        Returns: number
      }
      route_conversation_to_queue: {
        Args: { p_conversation_id: string; p_routing_queue_id: string }
        Returns: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_conversation_agent_assignment: {
        Args: { p_agent_id: string; p_conversation_id: string }
        Returns: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      set_my_assignment_availability: {
        Args: { p_available: boolean; p_organization_id: string }
        Returns: {
          available: boolean
          eligible: boolean
          last_heartbeat_at: string
          updated_at: string
        }[]
      }
      start_campaign: {
        Args: { p_campaign_id: string; p_organization_id: string }
        Returns: number
      }
      transfer_conversation_to_queue_with_private_note: {
        Args: {
          p_conversation_id: string
          p_target_routing_queue_id: string
          p_text: string
        }
        Returns: Json
      }
      transfer_conversation_with_private_note: {
        Args: {
          p_conversation_id: string
          p_target_agent_id: string
          p_text: string
        }
        Returns: Json
      }
      try_auto_assign_conversation: {
        Args: { p_conversation_id: string; p_source?: string }
        Returns: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      unassign_conversation_from_me: {
        Args: { p_conversation_id: string }
        Returns: {
          assigned_agent_id: string | null
          contact_address: string | null
          created_at: string
          extra: Json | null
          group_address: string | null
          id: string
          name: string | null
          organization_address: string
          organization_id: string
          routed_at: string | null
          routing_queue_id: string | null
          service: Database["public"]["Enums"]["service"]
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "conversations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_organization_auto_assignment: {
        Args: { p_enabled: boolean; p_organization_id: string }
        Returns: {
          auto_assign_conversations: boolean
          auto_save_whatsapp_contacts: boolean
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_automation_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_organization_chat_bubble_theme: {
        Args: { p_organization_id: string; p_theme: string }
        Returns: {
          chat_bubble_theme: string
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_ui_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_organization_contact_auto_save: {
        Args: { p_enabled: boolean; p_organization_id: string }
        Returns: {
          auto_assign_conversations: boolean
          auto_save_whatsapp_contacts: boolean
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_automation_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_platform_organization_agent: {
        Args: {
          p_agent_id: string
          p_name: string
          p_request_id?: string
          p_routing_queue_ids?: string[]
        }
        Returns: {
          ai: boolean
          created_at: string
          extra: Json | null
          id: string
          name: string
          organization_id: string
          picture: string | null
          updated_at: string
          user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "agents"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_platform_organization_agent_capacity: {
        Args: {
          p_max_agent_seats: number
          p_organization_id: string
          p_request_id: string
        }
        Returns: {
          max_agent_seats: number
          organization_id: string
          over_limit: boolean
          updated_at: string
          used_agent_seats: number
        }[]
      }
      update_platform_organization_auto_assignment: {
        Args: {
          p_enabled: boolean
          p_organization_id: string
          p_request_id: string
        }
        Returns: {
          auto_assign_conversations: boolean
          auto_save_whatsapp_contacts: boolean
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_automation_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_platform_organization_contact_auto_save: {
        Args: {
          p_enabled: boolean
          p_organization_id: string
          p_request_id: string
        }
        Returns: {
          auto_assign_conversations: boolean
          auto_save_whatsapp_contacts: boolean
          organization_id: string
          updated_at: string
          updated_by_scope: string
          updated_by_user_id: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organization_automation_settings"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_platform_organization_media_storage_quota: {
        Args: {
          p_organization_id: string
          p_quota_gb: number
          p_request_id: string
        }
        Returns: {
          last_reconciled_at: string
          object_count: number
          organization_id: string
          organization_name: string
          quota_bytes: number
          remaining_bytes: number
          storage_status: string
          updated_at: string
          usage_percent: number
          used_bytes: number
        }[]
      }
      update_platform_routing_queue: {
        Args: {
          p_agent_ids?: string[]
          p_name: string
          p_request_id?: string
          p_routing_queue_id: string
          p_status: string
        }
        Returns: {
          assignment_strategy: string
          created_at: string
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "routing_queues"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_platform_routing_queue_assignment_strategy: {
        Args: {
          p_organization_id: string
          p_request_id: string
          p_routing_queue_id: string
          p_strategy: string
        }
        Returns: {
          assignment_strategy: string
          created_at: string
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "routing_queues"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_quick_reply: {
        Args: {
          p_content: string
          p_quick_reply_id: string
          p_shortcut: string
        }
        Returns: {
          content: string
          created_at: string
          id: string
          organization_id: string
          shortcut: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "quick_replies"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_routing_queue: {
        Args: {
          p_agent_ids?: string[]
          p_name: string
          p_routing_queue_id: string
          p_status: string
        }
        Returns: {
          assignment_strategy: string
          created_at: string
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "routing_queues"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      update_routing_queue_assignment_strategy: {
        Args: { p_routing_queue_id: string; p_strategy: string }
        Returns: {
          assignment_strategy: string
          created_at: string
          id: string
          name: string
          organization_id: string
          status: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "routing_queues"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      upsert_whatsapp_contact_addresses: {
        Args: { p_addresses: Json }
        Returns: undefined
      }
      validate_quick_reply_input: {
        Args: { p_content: string; p_shortcut: string }
        Returns: undefined
      }
      validate_routing_queue_agent_ids: {
        Args: { p_agent_ids: string[]; p_organization_id: string }
        Returns: string[]
      }
    }
    Enums: {
      campaign_audience_type: "all_contacts" | "active_24h" | "csv_upload"
      direction: "incoming" | "outgoing" | "internal"
      log_level: "info" | "warning" | "error"
      role: "owner" | "admin" | "supervisor" | "member" | "agent"
      service:
        | "whatsapp"
        | "instagram"
        | "local"
        | "slack"
        | "discord"
        | "teams"
      webhook_operation: "insert" | "update"
      webhook_table:
        | "messages"
        | "conversations"
        | "organizations_addresses"
        | "contacts"
        | "contacts_addresses"
        | "logs"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  storage: {
    Tables: {
      buckets: {
        Row: {
          allowed_mime_types: string[] | null
          avif_autodetection: boolean | null
          created_at: string | null
          file_size_limit: number | null
          id: string
          name: string
          owner: string | null
          owner_id: string | null
          public: boolean | null
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string | null
        }
        Insert: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id: string
          name: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
        }
        Update: {
          allowed_mime_types?: string[] | null
          avif_autodetection?: boolean | null
          created_at?: string | null
          file_size_limit?: number | null
          id?: string
          name?: string
          owner?: string | null
          owner_id?: string | null
          public?: boolean | null
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string | null
        }
        Relationships: []
      }
      buckets_analytics: {
        Row: {
          created_at: string
          deleted_at: string | null
          format: string
          id: string
          name: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          format?: string
          id?: string
          name?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      buckets_vectors: {
        Row: {
          created_at: string
          id: string
          type: Database["storage"]["Enums"]["buckettype"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          id: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          type?: Database["storage"]["Enums"]["buckettype"]
          updated_at?: string
        }
        Relationships: []
      }
      iceberg_namespaces: {
        Row: {
          bucket_name: string
          catalog_id: string
          created_at: string
          id: string
          metadata: Json
          name: string
          updated_at: string
        }
        Insert: {
          bucket_name: string
          catalog_id: string
          created_at?: string
          id?: string
          metadata?: Json
          name: string
          updated_at?: string
        }
        Update: {
          bucket_name?: string
          catalog_id?: string
          created_at?: string
          id?: string
          metadata?: Json
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_namespaces_catalog_id_fkey"
            columns: ["catalog_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
        ]
      }
      iceberg_tables: {
        Row: {
          bucket_name: string
          catalog_id: string
          created_at: string
          id: string
          location: string
          name: string
          namespace_id: string
          remote_table_id: string | null
          shard_id: string | null
          shard_key: string | null
          updated_at: string
        }
        Insert: {
          bucket_name: string
          catalog_id: string
          created_at?: string
          id?: string
          location: string
          name: string
          namespace_id: string
          remote_table_id?: string | null
          shard_id?: string | null
          shard_key?: string | null
          updated_at?: string
        }
        Update: {
          bucket_name?: string
          catalog_id?: string
          created_at?: string
          id?: string
          location?: string
          name?: string
          namespace_id?: string
          remote_table_id?: string | null
          shard_id?: string | null
          shard_key?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "iceberg_tables_catalog_id_fkey"
            columns: ["catalog_id"]
            isOneToOne: false
            referencedRelation: "buckets_analytics"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "iceberg_tables_namespace_id_fkey"
            columns: ["namespace_id"]
            isOneToOne: false
            referencedRelation: "iceberg_namespaces"
            referencedColumns: ["id"]
          },
        ]
      }
      migrations: {
        Row: {
          executed_at: string | null
          hash: string
          id: number
          name: string
        }
        Insert: {
          executed_at?: string | null
          hash: string
          id: number
          name: string
        }
        Update: {
          executed_at?: string | null
          hash?: string
          id?: number
          name?: string
        }
        Relationships: []
      }
      objects: {
        Row: {
          bucket_id: string | null
          created_at: string | null
          id: string
          last_accessed_at: string | null
          metadata: Json | null
          name: string | null
          owner: string | null
          owner_id: string | null
          path_tokens: string[] | null
          updated_at: string | null
          user_metadata: Json | null
          version: string | null
        }
        Insert: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Update: {
          bucket_id?: string | null
          created_at?: string | null
          id?: string
          last_accessed_at?: string | null
          metadata?: Json | null
          name?: string | null
          owner?: string | null
          owner_id?: string | null
          path_tokens?: string[] | null
          updated_at?: string | null
          user_metadata?: Json | null
          version?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "objects_bucketId_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads: {
        Row: {
          bucket_id: string
          created_at: string
          id: string
          in_progress_size: number
          key: string
          metadata: Json | null
          owner_id: string | null
          upload_signature: string
          user_metadata: Json | null
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          id: string
          in_progress_size?: number
          key: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature: string
          user_metadata?: Json | null
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          id?: string
          in_progress_size?: number
          key?: string
          metadata?: Json | null
          owner_id?: string | null
          upload_signature?: string
          user_metadata?: Json | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
        ]
      }
      s3_multipart_uploads_parts: {
        Row: {
          bucket_id: string
          created_at: string
          etag: string
          id: string
          key: string
          owner_id: string | null
          part_number: number
          size: number
          upload_id: string
          version: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          etag: string
          id?: string
          key: string
          owner_id?: string | null
          part_number: number
          size?: number
          upload_id: string
          version: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          etag?: string
          id?: string
          key?: string
          owner_id?: string | null
          part_number?: number
          size?: number
          upload_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "s3_multipart_uploads_parts_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "s3_multipart_uploads_parts_upload_id_fkey"
            columns: ["upload_id"]
            isOneToOne: false
            referencedRelation: "s3_multipart_uploads"
            referencedColumns: ["id"]
          },
        ]
      }
      vector_indexes: {
        Row: {
          bucket_id: string
          created_at: string
          data_type: string
          dimension: number
          distance_metric: string
          id: string
          metadata_configuration: Json | null
          name: string
          updated_at: string
        }
        Insert: {
          bucket_id: string
          created_at?: string
          data_type: string
          dimension: number
          distance_metric: string
          id?: string
          metadata_configuration?: Json | null
          name: string
          updated_at?: string
        }
        Update: {
          bucket_id?: string
          created_at?: string
          data_type?: string
          dimension?: number
          distance_metric?: string
          id?: string
          metadata_configuration?: Json | null
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "vector_indexes_bucket_id_fkey"
            columns: ["bucket_id"]
            isOneToOne: false
            referencedRelation: "buckets_vectors"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      allow_any_operation: {
        Args: { expected_operations: string[] }
        Returns: boolean
      }
      allow_only_operation: {
        Args: { expected_operation: string }
        Returns: boolean
      }
      can_insert_object: {
        Args: { bucketid: string; metadata: Json; name: string; owner: string }
        Returns: undefined
      }
      extension: { Args: { name: string }; Returns: string }
      filename: { Args: { name: string }; Returns: string }
      foldername: { Args: { name: string }; Returns: string[] }
      get_common_prefix: {
        Args: { p_delimiter: string; p_key: string; p_prefix: string }
        Returns: string
      }
      get_size_by_bucket: {
        Args: never
        Returns: {
          bucket_id: string
          size: number
        }[]
      }
      list_multipart_uploads_with_delimiter: {
        Args: {
          bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_key_token?: string
          next_upload_token?: string
          prefix_param: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
        }[]
      }
      list_objects_with_delimiter: {
        Args: {
          _bucket_id: string
          delimiter_param: string
          max_keys?: number
          next_token?: string
          prefix_param: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      operation: { Args: never; Returns: string }
      search: {
        Args: {
          bucketname: string
          levels?: number
          limits?: number
          offsets?: number
          prefix: string
          search?: string
          sortcolumn?: string
          sortorder?: string
        }
        Returns: {
          created_at: string
          id: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_by_timestamp: {
        Args: {
          p_bucket_id: string
          p_level: number
          p_limit: number
          p_prefix: string
          p_sort_column: string
          p_sort_column_after: string
          p_sort_order: string
          p_start_after: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
      search_v2: {
        Args: {
          bucket_name: string
          levels?: number
          limits?: number
          prefix: string
          sort_column?: string
          sort_column_after?: string
          sort_order?: string
          start_after?: string
        }
        Returns: {
          created_at: string
          id: string
          key: string
          last_accessed_at: string
          metadata: Json
          name: string
          updated_at: string
        }[]
      }
    }
    Enums: {
      buckettype: "STANDARD" | "ANALYTICS" | "VECTOR"
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
  billing: {
    Enums: {},
  },
  public: {
    Enums: {
      campaign_audience_type: ["all_contacts", "active_24h", "csv_upload"],
      direction: ["incoming", "outgoing", "internal"],
      log_level: ["info", "warning", "error"],
      role: ["owner", "admin", "supervisor", "member", "agent"],
      service: ["whatsapp", "instagram", "local", "slack", "discord", "teams"],
      webhook_operation: ["insert", "update"],
      webhook_table: [
        "messages",
        "conversations",
        "organizations_addresses",
        "contacts",
        "contacts_addresses",
        "logs",
      ],
    },
  },
  storage: {
    Enums: {
      buckettype: ["STANDARD", "ANALYTICS", "VECTOR"],
    },
  },
} as const

