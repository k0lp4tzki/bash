#!/bin/bash
#Prompted by Dennis Kolpatzki (https://kolpatzki.de) and written by ChatGPT 4.0 
#because I'm lazy and need fast solutions to first-world problems.
#Database credentials
DB_USER="docmost"
DB_NAME="docmost"
DB_CONTAINER="docmost-db-1"
DB_PASSWORD="SuperSecretPassword"  # Replace with actual password
DOMAIN="http://public-url-that-should-be-used-for-invite"

#Query to get all invitations
QUERY="SELECT id, token, email FROM workspace_invitations;"

#Execute the query and store the result in a variable
INVITATIONS=$(docker exec -i $DB_CONTAINER env PGPASSWORD=$DB_PASSWORD \
    psql -U $DB_USER -d $DB_NAME -A -t -F"," -c "$QUERY")
    
#Check if we got any data
if [[ -z "$INVITATIONS" ]]; then
    echo "No invitations found!"
    exit 1
fi

#Print and process all invitations
echo "Generated Invitation Links:"
echo "------------------------------------"
echo "$INVITATIONS" | while IFS=',' read -r ID TOKEN EMAIL; do

    # Remove unnecessary spaces
    ID=$(echo $ID | xargs)
    TOKEN=$(echo $TOKEN | xargs)
    EMAIL=$(echo $EMAIL | xargs)

    #Ensure values are valid before printing
    if [[ -n "$ID" && -n "$TOKEN" && -n "$EMAIL" ]]; then
        INVITE_LINK="$DOMAIN/invites/$ID?token=$TOKEN"
        echo "Invitation for: $EMAIL"
        echo "Link: $INVITE_LINK"
        echo "------------------------------------"
    fi
done
