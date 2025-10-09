# System Library Module

## What This Module Does

The **System Library** is like the foundation of a house - it provides the basic tools and utilities that all other parts of the MongoDB hardening script need to work properly.

## Main Functions

### 🖥️ **System Management**
- **Checks if you have admin rights** - Makes sure you're running the script as an administrator (root user)
- **Installs missing tools** - Automatically downloads and installs any software tools the script needs
- **Creates folders** - Sets up the necessary directories on your computer with proper security permissions

### 📝 **Logging & Messages**
- **Shows colored messages** - Displays helpful information with colors and icons:
  - 🔵 Blue "ℹ" for general information
  - 🟢 Green "✓" for successful actions
  - 🟡 Yellow "⚠" for warnings
  - 🔴 Red "✗" for errors
  - 🔧 Cyan for completed fixes
- **Saves activity logs** - Keeps a record of everything the script does in log files for later review
- **Prints section headers** - Organizes information into clear sections with decorative lines

### ⚙️ **Configuration Management**
- **Asks for your preferences** - Prompts you to enter settings like:
  - MongoDB username and password
  - Which computers should be allowed to connect
  - How long to keep backup files
  - Your website domain name (required for security certificates)
- **Saves your settings** - Remembers your choices for future use
- **Validates inputs** - Makes sure the information you enter is correct (like checking if an IP address format is valid)

### 🔒 **Security Setup**
- **Creates secure folders** - Sets up directories with the right permissions so only authorized users can access them
- **Manages user accounts** - Creates and configures the special "mongodb" user account that runs the database
- **Sets file permissions** - Makes sure important files can only be read or changed by the right people

## Why This Module is Important

Think of this module as the **personal assistant** for the MongoDB hardening process. It:

1. **Handles the boring stuff** - Takes care of technical setup tasks automatically
2. **Keeps you informed** - Shows clear, easy-to-understand messages about what's happening
3. **Prevents mistakes** - Checks that everything is set up correctly before proceeding
4. **Maintains security** - Ensures all files and folders have proper security settings

## When This Module is Used

This module is used **throughout the entire hardening process** because other modules depend on its basic functions. It's like having a helpful assistant that:
- Greets you when the script starts
- Asks questions when it needs information
- Shows progress updates
- Reports problems if something goes wrong
- Celebrates successes when tasks complete

## User-Friendly Features

- **No technical jargon** - Messages are written in plain English
- **Visual feedback** - Uses colors and symbols to make information easy to understand
- **Interactive prompts** - Asks clear questions and provides helpful examples
- **Error prevention** - Warns you about potential issues before they become problems