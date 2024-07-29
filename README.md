Here's a `README.md` file for your project that explains how to use the `manage_domains.sh` script and initialize the server:

```markdown
# Server Management Script

This repository contains a shell script (`manage_domains.sh`) to manage a web server running multiple websites. The script can initialize the server, update current domains, add new domains, or remove existing domains. All websites are served by Apache and use Nginx as a reverse proxy, with Docker for container management.

## Features

- **Server Initialization**: Installs Docker, Apache, and other necessary packages. Sets up MariaDB and phpMyAdmin.
- **Domain Management**: Add, update, or remove domains, including configuration for Nginx and Docker.
- **SSL Certificate Management**: Uses `acme.sh` for SSL certificate issuance and renewal, with optional Cloudflare DNS integration.
- **Database Management**: Creates separate databases and users for each domain.

## Prerequisites

- Ubuntu Server
- Access to Cloudflare account (if using Cloudflare for DNS and SSL)
- Docker and Docker Compose installed

## Usage

### 1. Clone the Repository

```bash
git clone <repository-url>
cd <repository-directory>
```

### 2. Run the Script

```bash
chmod +x manage_domains.sh
./manage_domains.sh
```

### 3. Choose an Option

The script provides the following options:

1. **Initialize server**: Installs all necessary software and sets up the server.
2. **Update current domains**: Updates the configuration for existing domains.
3. **Add new domain**: Adds a new domain to the server, including database and SSL setup.
4. **Remove existing domain**: Removes a domain and its configuration from the server.

### Detailed Steps

#### Initialize Server

This option sets up the server with Docker, MariaDB, and other necessary packages. It will prompt you for the following:
- Whether to use Cloudflare for SSL (if yes, you'll need to provide your Cloudflare token and account ID).

#### Add New Domain

This option adds a new domain to the server. It will prompt you for the following:
- Domain name
- IP address
- Git repository address
- Webroot folder
- Database name, user, and password

#### Update Current Domains

This option updates the configuration for an existing domain. It will prompt you for the following:
- Select the domain to update
- New IP address (optional)
- New database credentials (optional)

#### Remove Existing Domain

This option removes a domain from the server. It will prompt you to select the domain to remove.

### Configuration Files

- **Nginx Configuration**: Stored in `nginx_conf` directory.
- **SSL Certificates**: Stored in `letsencrypt` directory.
- **Web Directories**: Stored in `web` directory.
- **Docker Compose Configuration**: Managed in `docker-compose.yml`.

### Example Commands

To initialize the server:

```bash
./manage_domains.sh
# Choose option 1: Initialize server
# Follow the prompts
```

To add a new domain:

```bash
./manage_domains.sh
# Choose option 3: Add new domain
# Follow the prompts
```

To update an existing domain:

```bash
./manage_domains.sh
# Choose option 2: Update current domains
# Follow the prompts
```

To remove an existing domain:

```bash
./manage_domains.sh
# Choose option 4: Remove existing domain
# Follow the prompts
```

### Security Considerations

- Ensure that Docker and MariaDB are properly secured.
- Use strong passwords for all database users.
- Keep your system and Docker images up-to-date.

### License

This project is licensed under the MIT License.

### Contributing

Contributions are welcome! Please fork the repository and create a pull request with your changes.

### Support

If you encounter any issues, please open an issue in the repository.

```

### Instructions

1. **Replace `<repository-url>` and `<repository-directory>` with the actual URL and directory of your repository.
2. **Ensure all paths and commands in the script and `README.md` match your project's structure and requirements.

This `README.md` file provides clear instructions on how to use the script to manage the server and domains, making it easier for users to get started.
