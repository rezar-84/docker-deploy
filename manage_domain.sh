#!/bin/bash

# Load Cloudflare credentials
export CF_Token=""
export CF_Account_ID=""

# Function to configure Cloudflare credentials
configure_cloudflare() {
  echo "Enter your Cloudflare API token:"
  read -s CF_Token
  echo "Enter your Cloudflare Account ID:"
  read CF_Account_ID

  # Store Cloudflare credentials for acme.sh
  echo "export CF_Token=$CF_Token" >> ~/.bashrc
  echo "export CF_Account_ID=$CF_Account_ID" >> ~/.bashrc
  source ~/.bashrc
}

# Function to install and initialize server
initialize_server() {
  echo "Initializing the server..."

  # Ask for CPU architecture
  echo "Enter CPU architecture (amd64/arm64):"
  read cpu_arch

  # Update and install necessary packages
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg lsb-release apache2-utils

  # Install Docker
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # Start and enable Docker
  sudo systemctl start docker
  sudo systemctl enable docker
  sudo usermod -aG docker $USER
  newgrp docker

  # Create necessary directories
  mkdir -p ~/projects/nginx_conf ~/projects/letsencrypt ~/projects/web

  # Install acme.sh
  curl https://get.acme.sh | sh
  source ~/.bashrc

  # Generate initial docker-compose.yml
  cat <<EOL > ~/projects/docker-compose.yml
services:
  mariadb:
    image: mariadb:latest
    container_name: mariadb
    platform: linux/$cpu_arch
    environment:
      MYSQL_ROOT_PASSWORD: your_root_password
    volumes:
      - db_data:/var/lib/mysql

  phpmyadmin:
    image: ${cpu_arch}-specific-image
    container_name: phpmyadmin
    platform: linux/$cpu_arch
    environment:
      PMA_HOST: mariadb
      PMA_USER: your_root_user
      PMA_PASSWORD: your_root_password
    ports:
      - "8080:80"
    depends_on:
      - mariadb

volumes:
  db_data:
EOL

  if [ "$cpu_arch" == "arm64" ]; then
    sed -i 's/${cpu_arch}-specific-image/arm64v8\/phpmyadmin:latest/' ~/projects/docker-compose.yml
  else
    sed -i 's/${cpu_arch}-specific-image/phpmyadmin\/phpmyadmin:latest/' ~/projects/docker-compose.yml
  fi

  echo "Server initialization complete."
}

# Function to list available domains
list_domains() {
  local domains=($(ls ./nginx_conf | sed 's/\.conf$//'))
  echo "Available domains:"
  for i in "${!domains[@]}"; do
    echo "$((i+1)). ${domains[$i]}"
  done
  echo "0. Add new domain"
  echo "q. Quit"
}

# Function to create Docker Compose service for a new website
create_docker_compose_service() {
  local domain=$1
  local dbname=$2
  local dbuser=$3
  local dbpass=$4
  local webroot=$5

  # Add service configuration for the new website in docker-compose.yml
  if ! grep -q "${domain}_apache" ~/projects/docker-compose.yml; then
    cat <<EOL >> ~/projects/docker-compose.yml

  ${domain}_apache:
    image: drupal:latest
    container_name: ${domain}_apache
    environment:
      DRUPAL_DB_HOST: mariadb
      DRUPAL_DB_NAME: ${dbname}
      DRUPAL_DB_USER: ${dbuser}
      DRUPAL_DB_PASSWORD: ${dbpass}
    volumes:
      - ./web/${domain}:${webroot}
    depends_on:
      - mariadb
EOL
  else
    echo "Service for ${domain} already exists in docker-compose.yml"
  fi

  update_docker_compose_nginx
}

# Function to create Nginx configuration for a new website
create_nginx_conf() {
  local domain=$1

  # Create Nginx server block configuration
  if [ ! -f "./nginx_conf/${domain}.conf" ]; then
    cat <<EOL > ./nginx_conf/${domain}.conf
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;  # Redirect HTTP to HTTPS
}

server {
    listen 443 ssl;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/${domain}/privkey.pem;

    location / {
        proxy_pass http://${domain}_apache;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~ /.well-known/acme-challenge {
        allow all;
    }

    # Deny access to the server IP
    if (\$host ~* ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$) {
        return 444;
    }
}
EOL
  else
    echo "Nginx configuration for ${domain} already exists"
  fi
}

# Function to update docker-compose.yml to include Nginx service if not already done
update_docker_compose_nginx() {
  if ! grep -q "nginx:" ~/projects/docker-compose.yml; then
    cat <<EOL >> ~/projects/docker-compose.yml

  nginx:
    image: nginx:latest
    container_name: nginx
    volumes:
      - ./nginx_conf:/etc/nginx/conf.d
      - ./letsencrypt:/etc/letsencrypt
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - mariadb
EOL
  fi

  # Add domain services as dependencies
  local domains=($(ls ./nginx_conf | sed 's/\.conf$//'))
  for domain in "${domains[@]}"; do
    if ! grep -q "${domain}_apache" ~/projects/docker-compose.yml; then
      echo "  - ${domain}_apache" >> ~/projects/docker-compose.yml
    fi
  done
}

# Function to create the necessary directories
create_directories() {
  local domain=$1
  mkdir -p web/${domain}
  mkdir -p nginx_conf
  mkdir -p letsencrypt/${domain}
}

# Function to issue SSL certificates using acme.sh
issue_ssl_certificate() {
  local domain=$1

  ~/.acme.sh/acme.sh --issue --dns dns_cf -d $domain
  ~/.acme.sh/acme.sh --install-cert -d $domain \
    --key-file ~/projects/letsencrypt/$domain/privkey.pem \
    --fullchain-file ~/projects/letsencrypt/$domain/fullchain.pem
}

# Function to update Cloudflare DNS
update_cloudflare_dns() {
  local domain=$1
  local ip=$2
  local zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${domain#*.}&status=active" \
    -H "Authorization: Bearer $CF_Token" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

  if [ -z "$zone_id" ]; then
    echo "Failed to get Cloudflare zone ID for ${domain#*.}"
    exit 1
  fi

  local record_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$domain" \
    -H "Authorization: Bearer $CF_Token" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

  if [ -z "$record_id" ]; then
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      -H "Authorization: Bearer $CF_Token" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}"
  else
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
      -H "Authorization: Bearer $CF_Token" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}"
  fi
}

# Function to create database and user
create_database() {
  local dbname=$1
  local dbuser=$2
  local dbpass=$3

  docker exec mariadb mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ${dbname};"
  docker exec mariadb mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${dbuser}'@'%' IDENTIFIED BY '${dbpass}';"
  docker exec mariadb mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON ${dbname}.* TO '${dbuser}'@'%';"
  docker exec mariadb mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"
}

# Function to apply security measures
apply_security_measures() {
  echo "Applying security measures..."

  # Secure MySQL installation
  docker exec -it mariadb mysql_secure_installation

  # Configure Docker to use user namespaces for better security
  sudo mkdir -p /etc/systemd/system/docker.service.d
  cat <<EOL | sudo tee /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --userns-remap=default
EOL
  sudo systemctl daemon-reload
  sudo systemctl restart docker

  # Store passwords securely
  echo "Enter the path to store secure passwords (e.g., /etc/secure):"
  read secure_path
  mkdir -p $secure_path
  chmod 700 $secure_path

  # Example of storing MySQL root password securely
  echo "Enter MySQL root password:"
  read -s mysql_root_password
  echo $mysql_root_password > $secure_path/mysql_root_password.txt
  chmod 600 $secure_path/mysql_root_password.txt

  echo "Security measures applied."
}

# Main menu function
main_menu() {
  while true; do
    echo "Choose an action:"
    echo "1. Configure Cloudflare"
    echo "2. Initialize Server"
    echo "3. Add/Edit Domain"
    echo "4. Apply Security Measures"
    echo "q. Quit"
    read choice

    case $choice in
      1)
        configure_cloudflare
        ;;
      2)
        initialize_server
        ;;
      3)
        echo "Enter the action: (a)dd new domain or (e)dit existing domain"
        read action

        if [ "$action" == "a" ]; then
          echo "Enter the new domain name:"
          read domain

          echo "Enter the database name:"
          read dbname

          echo "Enter the database user:"
          read dbuser

          echo "Enter the database password:"
          read -s dbpass

          echo "Enter the relative web root directory (e.g., docroot for web/domain/docroot):"
          read webroot

          create_directories $domain
          create_database $dbname $dbuser $dbpass
          create_docker_compose_service $domain $dbname $dbuser $dbpass $webroot
          create_nginx_conf $domain
          update_docker_compose_nginx

          echo "Enter the server IP address for DNS update:"
          read server_ip

          update_cloudflare_dns $domain $server_ip
          issue_ssl_certificate $domain

          echo "Starting Docker Compose services..."
          docker-compose up -d

          echo "Domain $domain has been successfully set up."
        else
          echo "Listing available domains..."
          list_domains
          echo "Enter the number of the domain you want to edit or 'q' to quit:"
          read domain_number

          if [ "$domain_number" == "q" ]; then
            continue
          fi

          if [ "$domain_number" -eq 0 ]; then
            echo "You chose to add a new domain. Running the setup for a new domain..."
            $0
          else
            local domains=($(ls ./nginx_conf | sed 's/\.conf$//'))
            local domain=${domains[$((domain_number-1))]}

            echo "You chose to edit the domain: $domain"
            echo "Do you want to (c)reate a new database or (u)pdate existing settings? (c/u)"
            read edit_action

            if [ "$edit_action" == "c" ]; then
              echo "Enter the new database name:"
              read dbname

              echo "Enter the new database user:"
              read dbuser

              echo "Enter the new database password:"
              read -s dbpass

              create_database $dbname $dbuser $dbpass
            fi

            echo "Updating SSL certificate and DNS settings for $domain..."
            issue_ssl_certificate $domain

            echo "Enter the server IP address for DNS update:"
            read server_ip

            update_cloudflare_dns $domain $server_ip

            echo "Restarting Docker Compose services..."
            docker-compose down
            docker-compose up -d

            echo "Domain $domain has been successfully updated."
          fi
        fi
        ;;
      4)
        apply_security_measures
        ;;
      q)
        echo "Quitting..."
        exit 0
        ;;
      *)
        echo "Invalid choice"
        ;;
    esac
  done
}

# Start the main menu
main_menu

