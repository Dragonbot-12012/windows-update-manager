## What changed

<!-- A short description of the change and the problem it solves. -->

## Type

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / cleanup
- [ ] Documentation
- [ ] Build / CI

## Testing

<!-- Describe what you ran. Paste the pass/fail summary from Test-WuManager.ps1. -->

- Windows version / build tested on:
- `.\src\Test-WuManager.ps1` result:

```
passed:  / failed:
```

- [ ] I tested `Disable` and `Enable` on a real machine or VM
- [ ] Services remained running after `Disable`
- [ ] `Enable` restored the pre-existing `SettingsPageVisibility` value exactly

## Checklist

- [ ] No service is stopped, disabled, or reconfigured by `Disable`
- [ ] Every change made by `Disable` is reversed by `Enable`
- [ ] Unrelated `Registry.pol` entries and `SettingsPageVisibility` tokens are preserved
- [ ] PowerShell 5.1 compatible (no `??`, no ternary, no `-Parallel`)
- [ ] No new runtime dependencies, network calls, or background processes
- [ ] Docs updated if behavior changed
