#!/bin/bash

# Load Cloudflare credentials
export CF_Token=""
export CF_Account_ID=""

# Function to install and initialize server
initialize_server() {
  echo "Initializing the server..."
  
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
}

# Function to create Docker Compose service for a new website
create_docker_compose_service() {
  local domain=$1
  local dbname=$2
  local dbuser=$3
  local dbpass=$4
  local git_repo=$5
  local webroot=$6

  # Add service configuration for the new website in docker-compose.yml
  if ! grep -q "${domain}_apache" docker-compose.yml; then
    cat <<EOL >> docker-compose.yml

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
  if ! grep -q "nginx:" docker-compose.yml; then
    cat <<EOL >> docker-compose.yml

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

# Main script
echo "Choose an option:"
echo "1. Initialize server"
echo "2. Update current domains"
echo "3. Add new domain"
echo "4. Remove existing domain"
read option

if [[ "$option" == "1" ]]; then
  initialize_server

  echo "Do you want to use Cloudflare for SSL? (y/n)"
  read use_cf
  if [[ "$use_cf" == "y" ]]; then
    echo "Enter Cloudflare Token:"
    read CF_Token
    echo "Enter Cloudflare Account ID:"
    read CF_Account_ID
  fi

  echo "Server initialized successfully."

elif [[ "$option" == "2" ]]; then
  list_domains
  echo "Select the domain you want to update:"
  read selection

  domains=($(ls ./nginx_conf | sed 's/\.conf$//'))
  domain=${domains[$((selection-1))]}

  echo "Editing domain: $domain"
  echo "Enter the new IP address for the domain (leave blank to keep current):"
  read ip

  if [[ -n "$ip" ]]; then
    update_cloudflare_dns $domain $ip
  fi

  echo "Enter the new database name for the website (leave blank to keep current):"
  read dbname

  echo "Enter the new database user for the website (leave blank to keep current):"
  read dbuser

  echo "Enter the new database password for the website (leave blank to keep current):"
  read -s dbpass

  if [[ -n "$dbname" && -n "$dbuser" && -n "$dbpass" ]]; then
    create_database $dbname $dbuser $dbpass
  fi

  # Reissue SSL certificate
  issue_ssl_certificate $domain

  echo "Configuration for ${domain} updated successfully."

elif [[ "$option" == "3" ]]; then
  echo "Enter the domain name for the new website:"
  read domain

  echo "Enter the IP address for the new domain:"
  read ip

  echo "Enter the Git repository address for the website:"
  read git_repo

  echo "Enter the webroot folder for the website:"
  read webroot

  echo "Enter the database name for the new website:"
  read dbname

  echo "Enter the database user for the new website:"
  read dbuser

  echo "Enter the database password for the new website:"
  read -s dbpass

  # Create directories for the new website
  create_directories $domain

  # Create Docker Compose service for the new website
  create_docker_compose_service $domain $dbname $dbuser $dbpass $git_repo $webroot

  # Create Nginx configuration for the new website
  create_nginx_conf $domain

  # Update Docker Compose to include Nginx service if not already done
  update_docker_compose_nginx

  # Create database and user
  create_database $dbname $dbuser $dbpass

  # Issue SSL certificate
  issue_ssl_certificate $domain

  # Update Cloudflare DNS
  update_cloudflare_dns $domain $ip

  echo "Setup for ${domain} completed successfully."

elif [[ "$option" == "4" ]]; then
  list_domains
  echo "Select the domain you want to remove:"
  read selection

  domains=($(ls ./nginx_conf | sed 's/\.conf$//'))
  domain=${domains[$((selection-1))]}

  echo "Removing domain: $domain"

  # Remove Nginx configuration
  rm ./nginx_conf/${domain}.conf

  # Remove web directory
  rm -rf ./web/${domain}

  # Remove Docker Compose service
  sed -i "/${domain}_apache:/,/depends_on: mariadb/d" docker-compose.yml

  # Remove SSL certificates
  rm -rf ./letsencrypt/${domain}

  echo "Domain ${domain} removed successfully."
else
  echo "Invalid option. Please choose a valid option."
fi

# Reload Nginx to apply the new configuration
docker-compose restart nginx

echo "Nginx configuration reloaded."
