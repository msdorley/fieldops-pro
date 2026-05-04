@{
    # ── Organisation ─────────────────────────────────────────────────
    OrgName          = "Contoso Europe"          # Your company name
    TenantID         = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # Azure AD tenant ID
 
    # ── VPN ──────────────────────────────────────────────────────────
    VPNPortal        = "vpn.contoso.eu"          # GlobalProtect portal FQDN
 
    # ── Software deployment list (winget IDs) ─────────────────────────
    SoftwareList     = @(
        "7zip.7zip"
        "Notepad++.Notepad++"
        "Google.Chrome"
        "Adobe.Acrobat.Reader.64-bit"
        "Microsoft.Teams"
    )
 
    # ── Logging ──────────────────────────────────────────────────────
    LogRetentionDays = 90    # GDPR: logs auto-purged after this many days
 
    # ── Locale ───────────────────────────────────────────────────────
    DefaultLanguage  = "EN"
}
