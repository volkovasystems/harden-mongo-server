# Contributing to MongoDB Server Hardening Script

We welcome contributions to make this script even better! This document provides guidelines for contributing to the project.

## 🤝 Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help maintain a welcoming environment for all contributors
- Security issues should be reported privately

## 🚀 Quick Start

1. **Fork the repository**
2. **Clone your fork**:
   ```bash
   git clone https://github.com/yourusername/harden-mongo-server.git
   cd harden-mongo-server
   ```
3. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes**
5. **Test thoroughly** (see Testing section below)
6. **Commit your changes** (see Commit Guidelines below)
7. **Push and create a Pull Request**

## 🎯 How to Contribute

### Bug Reports
- Use the GitHub issue tracker
- Provide clear steps to reproduce
- Include system information (OS, MongoDB version, etc.)
- Include relevant log files or error messages
- Check if the issue already exists

### Feature Requests
- Open an issue with the "enhancement" label
- Describe the use case and expected behavior
- Consider if it fits with the project's security-first philosophy
- Discuss implementation approach

### Security Issues
- **DO NOT** open public issues for security vulnerabilities
- Email security issues privately to the maintainers
- Include detailed reproduction steps
- Allow time for assessment and patching

### Code Contributions
- Follow the coding standards below
- Include tests for new functionality
- Update documentation as needed
- Ensure backwards compatibility when possible

## 📋 Development Guidelines

### Coding Standards

#### Shell Script Best Practices
```bash
# Use strict error handling
set -e

# Always quote variables
echo "$VARIABLE"

# Use meaningful function names
ensure_mongodb_secure() {
    # Function implementation
}

# Include help text for functions
function_name() {
    # Description: Brief description of what the function does
    # Parameters: $1 - description, $2 - description
    # Returns: 0 on success, 1 on error
}
```

#### User Experience Guidelines
- **Use clear, non-technical language** in user-facing messages
- **Provide explanations** for security measures using `log_and_print "EXPLAIN"`
- **Include examples** in help text and error messages
- **Test with non-expert users** to ensure clarity
- **Use consistent terminology** throughout the script

#### Security Standards
- **Never expose secrets** in logs or output
- **Validate all inputs** before processing
- **Use secure defaults** for all configurations
- **Follow principle of least privilege**
- **Implement proper error handling**

#### SSL/TLS Standards
- **Always validate certificates** properly
- **Use strong cryptographic standards** (RSA 2048+ bits)
- **Implement proper certificate rotation**
- **Validate domain names** before certificate generation
- **Handle certificate errors gracefully**

### Testing

#### Manual Testing
Test on a clean Ubuntu/Debian system:
```bash
# Test full hardening
sudo ./harden-mongo-server.sh --dry-run
sudo MONGO_DOMAIN="test.example.com" ./harden-mongo-server.sh

# Test individual commands
sudo ./harden-mongo-server.sh status
sudo ./harden-mongo-server.sh maintenance security-check
sudo ./harden-mongo-server.sh ssl-renew

# Test error conditions
# - Run without domain
# - Run with invalid domain
# - Run with port 80 occupied
```

#### Automated Testing
- Test script functionality without modifying the system
- Validate configuration file generation
- Check command-line argument parsing
- Test error handling paths

#### Security Testing
- Validate firewall rules are correctly applied
- Confirm SSL certificates are properly configured
- Test authentication mechanisms
- Verify file permissions are secure

### Documentation

#### Code Documentation
- Comment complex logic and security-critical sections
- Include function descriptions with parameters and return values
- Document any non-obvious configuration choices
- Update help text when adding new features

#### User Documentation
- Update README.md for new features
- Add examples for new functionality
- Update CHANGELOG.md following semantic versioning
- Include migration guides for breaking changes

## 🔧 Commit Guidelines

### Commit Message Format
```
type(scope): brief description

Longer description if needed, explaining what and why.

- Bullet points for multiple changes
- Reference issues with #123
```

#### Types
- `feat`: New feature
- `fix`: Bug fix
- `security`: Security improvement
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

#### Examples
```bash
feat(ssl): add automatic certificate renewal system

Implements systemd timer for monthly certificate renewal including
both Let's Encrypt and client certificates. Includes proper error
handling and logging.

- Add systemd service and timer files
- Update certificate renewal script
- Add status checking for renewal system
- Closes #42

fix(auth): handle existing admin user correctly

Previously failed when admin user already existed. Now properly
detects existing user and validates credentials.

security(config): strengthen SSL configuration

- Set allowConnectionsWithoutCertificates to false
- Add certificate hostname validation
- Update cipher suite to exclude weak ciphers
```

## 📊 Pull Request Process

### Before Submitting
1. **Test your changes** on a clean system
2. **Update documentation** if needed
3. **Add/update tests** for new functionality
4. **Check for security implications**
5. **Ensure backwards compatibility** or document breaking changes

### Pull Request Template
```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Security improvement
- [ ] Documentation update
- [ ] Breaking change

## Testing
- [ ] Tested on Ubuntu 20.04/22.04
- [ ] Tested with existing MongoDB installation
- [ ] Tested SSL certificate generation
- [ ] Tested error conditions

## Security Considerations
- [ ] No credentials exposed in logs
- [ ] Proper input validation
- [ ] Secure defaults maintained
- [ ] Certificate handling secure

## Documentation
- [ ] Updated README.md if needed
- [ ] Updated CHANGELOG.md
- [ ] Added code comments
- [ ] Updated help text
```

### Review Process
1. **Automated checks** must pass
2. **Manual testing** by maintainers
3. **Security review** for security-related changes
4. **Documentation review** for user-facing changes
5. **Integration testing** with existing functionality

## 🚨 Security Considerations

### Reporting Security Issues
- **Never** disclose security vulnerabilities publicly
- Email details privately to project maintainers
- Include proof of concept if applicable
- Allow reasonable time for fixing before disclosure

### Security-First Development
- **Default to secure configurations**
- **Validate all external inputs**
- **Never log sensitive information**
- **Use established cryptographic libraries**
- **Follow OWASP guidelines**

### Certificate Security
- **Validate certificate chains** properly
- **Check certificate expiry** before use
- **Use strong key sizes** (RSA 2048+ bits)
- **Implement proper certificate rotation**
- **Secure private key storage** (600 permissions)

## 🏷️ Release Process

### Version Numbers
We follow [Semantic Versioning](https://semver.org/):
- **MAJOR**: Breaking changes (e.g., mandatory SSL)
- **MINOR**: New features (backwards compatible)
- **PATCH**: Bug fixes and security updates

### Release Checklist
- [ ] Update CHANGELOG.md
- [ ] Update version numbers in script
- [ ] Test on clean systems
- [ ] Update documentation
- [ ] Create release notes
- [ ] Tag release in git

## 💬 Getting Help

### Discussion Channels
- **GitHub Issues**: Bug reports and feature requests
- **GitHub Discussions**: General questions and ideas
- **Pull Requests**: Code review and discussion

### Maintainer Response
- **Bug reports**: Within 7 days
- **Feature requests**: Within 14 days
- **Security issues**: Within 24 hours
- **Pull requests**: Within 14 days

## 📚 Resources

### MongoDB Security
- [MongoDB Security Checklist](https://docs.mongodb.com/manual/administration/security-checklist/)
- [MongoDB SSL/TLS Configuration](https://docs.mongodb.com/manual/tutorial/configure-ssl/)

### Shell Scripting
- [Bash Style Guide](https://google.github.io/styleguide/shellguide.html)
- [ShellCheck](https://www.shellcheck.net/) - Static analysis tool

### SSL/TLS Security
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [SSL/TLS Best Practices](https://wiki.mozilla.org/Security/Server_Side_TLS)

---

Thank you for contributing to MongoDB Server Hardening Script! Your efforts help make MongoDB deployments more secure for everyone. 🔒