import Foundation
import Supabase

/// The app's single Supabase client. The URL and anon key are PUBLIC by design —
/// the anon key ships in every client build, and row-level security (not secrecy)
/// is what protects each user's data. The service_role key is never here.
enum Backend {
    static let client = SupabaseClient(
        supabaseURL: URL(string: "https://rrkvlrtohmylhslpzuvz.supabase.co")!,
        supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJya3ZscnRvaG15bGhzbHB6dXZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc0NDM2MzksImV4cCI6MjEwMzAxOTYzOX0.dvXo9pVFu_NbVZznvc4RoAzxZ3AecyC9iKcu3EXg14g"
    )
}
