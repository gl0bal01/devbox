# Contributing to DevBox

Thank you for your interest in contributing to DevBox. This document provides guidelines for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How to Contribute](#how-to-contribute)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Commit Guidelines](#commit-guidelines)
- [Pull Request Process](#pull-request-process)
- [Testing](#testing)
- [Documentation](#documentation)

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help maintain a welcoming environment for all contributors

## How to Contribute

### Reporting Issues

Before creating an issue:

1. Search existing issues to avoid duplicates
2. Use the issue templates if available
3. Include relevant details:
   - Operating system and version
   - Docker version
   - Steps to reproduce
   - Expected vs actual behavior
   - Error messages and logs

### Suggesting Features

1. Open an issue with the "feature request" label
2. Describe the use case and benefits
3. Consider implementation complexity

### Submitting Changes

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Test your changes
5. Submit a pull request

## Development Setup

### Prerequisites

- Ubuntu 24.04 (or compatible Linux distribution)
- Docker and Docker Compose
- Git
- Bash 5.0 or later

### Local Development

```bash
# Clone your fork
git clone https://github.com/gl0bal01/devbox.git
cd devbox

# Create a feature branch
git checkout -b feature/your-feature-name

# Make changes and test
./setup.sh  # Test on a development VPS
```

### Testing Environment

For testing, use a fresh VPS instance:

- Hostinger, Hetzner, DigitalOcean, or similar
- Ubuntu 24.04 with Docker pre-installed
- Minimum 4GB RAM

## Coding Standards

### Shell Scripts

Follow these conventions for shell scripts:

1. **Shebang**: Use `#!/usr/bin/env bash`
2. **Error handling**: Use `set -euo pipefail`
3. **Quoting**: Always quote variables: `"$variable"`
4. **Functions**: Use lowercase with underscores: `my_function()`
5. **Constants**: Use uppercase: `MY_CONSTANT`

**Example**:

```bash
#!/usr/bin/env bash
set -euo pipefail

MY_CONSTANT="value"

my_function() {
    local input="$1"
    echo "Processing: $input"
}

main() {
    my_function "$MY_CONSTANT"
}

main "$@"
```

### Documentation

1. Use Markdown for all documentation
2. Follow the structure in existing docs
3. Use clear, simple language
4. Include code examples where helpful
5. Avoid jargon and idioms

### Docker Compose Files

1. Use version 3.8 or later syntax
2. Include health checks for all services
3. Apply security hardening (no-new-privileges, cap_drop)
4. Use resource limits
5. Document with comments

## Commit Guidelines

### Commit Message Format

```
type: short description

Longer description if needed.

- Detail 1
- Detail 2
```

### Commit Types

| Type | Description |
|------|-------------|
| feat | New feature |
| fix | Bug fix |
| docs | Documentation changes |
| style | Formatting, no code change |
| refactor | Code restructuring |
| test | Adding tests |
| chore | Maintenance tasks |

### Examples

```
feat: add GPU detection for Ollama

Automatically detects NVIDIA GPUs and configures
Ollama to use GPU acceleration.

- Added nvidia-smi check
- Updated docker-compose for GPU passthrough
```

```
fix: correct SSH port in firewall rules

UFW rules were using port 22 instead of configured
SSH_PORT variable.
```

```
docs: add troubleshooting section for VPN issues
```

## Pull Request Process

### Before Submitting

1. Test your changes on a fresh VPS
2. Update documentation if needed
3. Ensure no sensitive data is included (IPs, keys, passwords)
4. Run shellcheck on shell scripts:
   ```bash
   shellcheck setup.sh
   ```

### Pull Request Template

When creating a pull request, include:

1. **Description**: What does this change do?
2. **Motivation**: Why is this change needed?
3. **Testing**: How was this tested?
4. **Checklist**:
   - [ ] Tested on fresh Ubuntu 24.04 VPS
   - [ ] Documentation updated
   - [ ] No hardcoded secrets or IPs
   - [ ] Shell scripts pass shellcheck

### Review Process

1. Maintainers will review within 1-2 weeks
2. Address feedback promptly
3. Keep discussions focused and constructive

## Testing

### Manual Testing Checklist

Test these scenarios before submitting:

1. **Fresh installation**: Run setup.sh on new VPS
2. **Idempotency**: Run setup.sh twice, verify no errors
3. **Services**: Verify all services start and are accessible
4. **Security**: Run security-check.sh
5. **AI tools**: Test install-ai-dev-stack.sh

### Security Testing

Always verify:

- No secrets in logs or output
- Correct file permissions (600 for sensitive files)
- Services only accessible via Tailscale
- UFW rules correct

## Documentation

### Where to Document

| Change Type | Documentation Location |
|-------------|------------------------|
| New feature | README.md, relevant docs/ file |
| Configuration | README.md Configuration section |
| Troubleshooting | docs/troubleshooting.md |
| Commands | docs/quick-reference.md |

### Documentation Standards

1. Use present tense ("Add feature" not "Added feature")
2. Be concise and clear
3. Include examples for complex features
4. Update the "Last updated" date

## Questions

For questions about contributing:

1. Check existing documentation
2. Search closed issues
3. Open a new issue with the "question" label

Thank you for contributing to DevBox.
