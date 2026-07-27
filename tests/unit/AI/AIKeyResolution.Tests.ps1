#Requires -Version 5.1
<#
    FieldOps Pro - Phase 6, Stream 6.5 (PR 5b-2a: key resolution convergence)

    Tests that the AI client and Invoke-ComplianceDiff resolve the API key the
    same way.

    THE BUG THIS PREVENTS

    Before convergence there were two resolvers. Invoke-ComplianceDiff searched
    four candidate config files with a recursive alias walk; the client read
    top-level properties of technician.json only. A technician whose key lived
    in FieldOps.config.json, or nested under an object, got a banner reading
    "AI ENABLED" from the script and NoApiKey from the client on every call --
    a silent downgrade to local rules, with the UI actively saying otherwise.

    Routing ComplianceDiff through the client (PR5b-2b) would have made that
    divergence load-bearing. One resolver, one answer, asserted here.

    PRECEDENCE NOTE

    ANTHROPIC_API_KEY now wins over config, where ComplianceDiff previously
    preferred config. This only bites when both are set to DIFFERENT keys, and
    environment-wins is both the Anthropic convention and the behaviour that
    lets a technician override a stale provisioned key without editing the USB.
    It is asserted below so the choice is visible rather than incidental.
#>

BeforeAll {
    $script:TestsRoot  = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:RepoRoot   = Split-Path $script:TestsRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'SCRIPTS\AI\FieldOps-AIClient.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    # Each test gets an isolated CONFIG directory; nothing here touches the repo.
    function New-TestConfigDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("fieldops-keytest-" + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d -Force
        return $d
    }
    function Set-TestConfigFile {
        param([string]$Dir, [string]$Name, $Object)
        $path = Join-Path $Dir $Name
        ($Object | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }

    $script:SavedEnvKey = $env:ANTHROPIC_API_KEY
    $env:ANTHROPIC_API_KEY = $null
}

AfterAll {
    $env:ANTHROPIC_API_KEY = $script:SavedEnvKey
    Remove-Module 'FieldOps-AIClient' -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
Describe 'Candidate file search matches Invoke-ComplianceDiff' -Tag 'Fast' {

    It 'searches the four known config filenames in preference order' {
        InModuleScope 'FieldOps-AIClient' {
            $paths = @(Get-AIConfigCandidatePath -ConfigDir 'C:\fake\CONFIG')
            @($paths | ForEach-Object { Split-Path $_ -Leaf }) |
                Should -Be @('technician.json','FieldOps.config.json','fieldops.json','config.json')
        }
    }

    It 'finds a key in technician.json' {
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-fromtechnician' }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-fromtechnician'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'finds a key in FieldOps.config.json when technician.json is absent' {
        # The legacy filename. This is the case the old client missed entirely.
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'FieldOps.config.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-fromlegacy' }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-fromlegacy'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'prefers technician.json when several candidates carry a key' {
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-preferred' }
            $null = Set-TestConfigFile -Dir $dir -Name 'config.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-ignored' }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-preferred'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not let a keyless technician.json mask a real key further down' {
        # A provisioning stub with only a name in it must not end the search.
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' `
                        -Object @{ TechnicianName = 'Ousman' }
            $null = Set-TestConfigFile -Dir $dir -Name 'fieldops.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-realkey' }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-realkey'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'skips a malformed file and keeps searching' {
        $dir = New-TestConfigDir
        try {
            'this is not json {{{' | Set-Content -LiteralPath (Join-Path $dir 'technician.json') -Encoding UTF8
            $null = Set-TestConfigFile -Dir $dir -Name 'config.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-survivor' }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-survivor'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'returns empty when no candidate file exists' {
        $dir = New-TestConfigDir
        try {
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be ''
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ==============================================================================
Describe 'Alias and nesting behaviour matches Find-ConfigValue' -Tag 'Fast' {

    It 'accepts every alias Invoke-ComplianceDiff accepts' {
        foreach ($alias in @('AnthropicApiKey','AnthropicKey','ApiKey','AiKey','ClaudeApiKey','ClaudeKey','Key')) {
            $dir = New-TestConfigDir
            try {
                $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' -Object @{ $alias = 'sk-ant-api03-aliased' }
                InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir; A = $alias } {
                    param($D, $A)
                    Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-aliased' -Because "alias $A must resolve"
                }
            } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'finds a key nested inside an object' {
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' `
                        -Object @{ technician = @{ name = 'Ousman' }; anthropic = @{ ApiKey = 'sk-ant-api03-nested' } }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-nested'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not stringify a nested object when the outer key matches an alias' {
        # {"Key":{"value":"..."}} must not resolve to "@{value=...}".
        InModuleScope 'FieldOps-AIClient' {
            $obj = [PSCustomObject]@{ Key = [PSCustomObject]@{ value = 'sk-ant-api03-inner' } }
            $v = Find-AIConfigValue -Obj $obj -Aliases @('Key','ApiKey')
            $v | Should -Not -Match '@\{'
        }
    }

    It 'ignores an empty or whitespace value' {
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' -Object @{ ApiKey = '   ' }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be ''
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'terminates on a self-referential depth without hanging' {
        InModuleScope 'FieldOps-AIClient' {
            $deep = [PSCustomObject]@{ a = [PSCustomObject]@{ b = [PSCustomObject]@{ c = [PSCustomObject]@{
                        d = [PSCustomObject]@{ e = [PSCustomObject]@{ f = [PSCustomObject]@{ ApiKey = 'too-deep' } } } } } } }
            Find-AIConfigValue -Obj $deep -Aliases @('ApiKey') | Should -Be $null
        }
    }
}

# ==============================================================================
Describe 'Environment precedence' -Tag 'Fast' {

    AfterEach { $env:ANTHROPIC_API_KEY = $null }

    It 'prefers ANTHROPIC_API_KEY over any config file' {
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-fromfile' }
            $env:ANTHROPIC_API_KEY = 'sk-ant-api03-fromenv'
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-fromenv'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'falls back to config when the environment variable is unset' {
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-fromfile' }
            InModuleScope 'FieldOps-AIClient' -Parameters @{ D = $dir } {
                param($D)
                Get-AIApiKey -ConfigDir $D | Should -Be 'sk-ant-api03-fromfile'
            }
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ==============================================================================
Describe 'Availability reporting reflects the converged resolver' -Tag 'Fast' {

    It 'reports HasApiKey true for a key the old resolver would have missed' {
        # The exact silent-degradation case: key in the legacy file, nested.
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'FieldOps.config.json' `
                        -Object @{ anthropic = @{ ApiKey = 'sk-ant-api03-legacynested' } }
            $r = Test-FieldOpsAIAvailability -ConfigDir $dir
            $r.HasApiKey | Should -BeTrue
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'never surfaces the key itself (6.5-R12)' {
        $dir = New-TestConfigDir
        try {
            $null = Set-TestConfigFile -Dir $dir -Name 'technician.json' `
                        -Object @{ AnthropicApiKey = 'sk-ant-api03-mustnotleak' }
            $r = Test-FieldOpsAIAvailability -ConfigDir $dir
            ($r | ConvertTo-Json -Depth 5) | Should -Not -Match 'mustnotleak'
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
