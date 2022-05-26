#!/usr/bin/env fish
#
# Create content in RStudio Connect with a given title. Does not prevent the
# creation of duplicate titles. Subsequently, create a bundle, upload that
# bundle to RStudio Connect, deploy that bundle, then wait for deployment to
# complete.
#
# Run this script from the content root directory.
#
# This script is translated into a fish shell script.
#
# DEPENDENCIES:
# - jq-1.6
# - curl-7.83.1
# - Rscript-4.1.2 and R-package "rsconnect" version >= 0.8.15
# - tar-3.5.1
# Global variables {{{

# Initialize empty variable that containes the names of the files created at runtime
set --global files_to_be_cleaned_on_error
set --global files_to_be_cleaned_on_success
# Random number as a name for the content item to be deployed.
# The "name" field should not collide with other names for all content deployed by one user 
# and is therefore created randomly.
# See https://docs.rstudio.com/connect/cookbook/deploying/#creating-content for details.
set --global content_name (string join '' (random) (random))
set --global api_path "__api__/v1/"

#}}}
# function definitions {{{

# clean_up {{{

function clean_up
	echo "Clean up..."
	for file in $argv
		if test \( -e "$file" \) 
			rm -f $file
			echo "File $file removed."
		end
	end
end

#}}}
# remove_content_item {{{

function remove_content_item
	if test \( -n "$argv" \)
		set --local endpoint_delete_content (string join '' $CONNECT_SERVER $api_path "content/" "$argv")
		echo "Removing content item $argv"
		set --local response_to_deleted_content (\
			curl --silent --insecure --show-error --location --max-redirs 0 --fail --request DELETE \
				--header "Authorization: Key $CONNECT_API_KEY" \
				$endpoint_delete_content \
				)
		if ! test \( $status -eq 0 \)
			set --local error_msg (echo $response_to_deleted_content | jq --raw-output '.error')
			echo "Deletion of content item $argv unsuccessful."
			echo "Message: "
			set_color yellow
			echo "	$error_msg"
			set_color normal
		else
			echo "Deletion of content item $argv successful."
		end
	end
end

#}}}

#}}}
# Checks in advance {{{

if ! test \( -n "$argv" \)
	echo "Please provide a title for the content to be deployed: "
	echo "##################################################"
	printf "	Usage: %s <content-title>\n" (status basename)
	echo "##################################################"
	exit 1
else
	set --global content_title $argv[1]
	echo "##################################################"
	echo "Deploy content $title"
	echo "##################################################"
end

# If the CONNECT_SERVER environment variable is not defined
# exit with a warning
# Syntax: the escaped paranthesis are optional. See also https://fishshell.com/docs/current/cmds/test.html#cmd-test
if ! test \( -n "$CONNECT_SERVER" \)
	echo "The CONNECT_SERVER environment variable is not defined. It defines"
	echo "the base URL of your RStudio Connect instance."
	echo 
	echo "    export CONNECT_SERVER='http://connect.company.com/'"
	exit 1
end

if ! test \( -n "$CONNECT_API_KEY" \)
	echo "The CONNECT_API_KEY environment variable is not defined. It must contain"
	echo "an API key owned by a 'publisher' account in your RStudio Connect instance."
	echo
	echo "    export CONNECT_API_KEY='jIsDWwtuWWsRAwu0XoYpbyok2rlXfRWa'"
	exit 1
end

if ! test \( -e "app.R" \) 
	echo "The file app.R does not exist. It serves rsconnect as an entry point to the shiny app."
	echo "Create it?"
	set --local create_app_r_file (string trim (read --prompt-str "y/n?: "))
	if test \( "$create_app_r_file" = "y" \)
		printf "# Launch the ShinyApp (Do not remove this comment)\n#To deploy, run: rsconnect::deployApp()\n#Or use the blue button on top of this file\n\npkgload::load_all(export_all = FALSE, helpers = FALSE, attach_testthat = FALSE)\nrun_app()" > app.R
		set --global files_to_be_cleaned_on_error $files_to_be_cleaned_on_error app.R
		echo "File app.R created"
	else
		echo "Exiting..."
		exit 1
	end
end

if ! test \( -e "manifest.json" \)
	echo "An RS Connect manifest file does not exist. This file is crucial for RS Connect to deploy the app."
	echo "Create it?"
	set --local create_manifest_file (read --prompt-str "y/n: " | string trim)
	if test \( $create_manifest_file = "y" \) 
		Rscript --vanilla -e "rsconnect::writeManifest()" > /dev/null 2>error_msgs_rscript.tmp
		set --global files_to_be_cleaned_on_error $files_to_be_cleaned_on_error manifest.json
		# Did Rscript print out any warnings or errors? If yes, than exit.
		if test \( (cat error_msgs_rscript.tmp | wc -l | string trim) != "0" \)
			echo "A manifest file could not be created without errors."
			clean_up $files_to_be_cleaned_on_error
			echo "Exiting..."
			exit 1
		else
			echo "Manifest file manifest.json created"
			if test \( -e error_msgs_rscript.tmp \) 
				rm -f error_msgs_rscript.tmp
			end
		end
	end
end

#}}}
# Programm {{{
# Create archive file {{{

set --local bundle_path "bundle.tar.gz"
set --local files_to_deploy_all app.R manifest.json R man DESCRIPTION NAMESPACE .Rbuildignore .Renviron man-roxygen README.md data-raw data inst
set --global files_to_deploy
set --global files_missing
echo "Zip directory content to $bundle_path:"
for file in $files_to_deploy_all
	if test \( -e "$file" \) 
		set --global files_to_deploy $files_to_deploy $file
	else
		set --global files_missing $files_missing $file
	end
end
if test \( -n "$files_missing" \)
	echo "The files:"
	set_color yellow
	echo "	$files_missing" 
	set_color normal
	echo "are not contained in the currend working directory."
	echo "Continue? "
	if test \( (read --prompt-str "y/n: " | string trim) != "y" \)
		clean_up $files_to_be_cleaned_on_error
		echo "Exiting..."
		exit 1
	else
		tar czf $bundle_path $files_to_deploy
		echo "Archive file created."
		set --global files_to_be_cleaned_on_success $files_to_be_cleaned_on_success bundle.tar.gz
	end
end

#}}}
# create content at RS Connect {{{
# For api endpoint details see https://docs.rstudio.com/connect/api/#tag--Content-V1-Experimental
# For workflows suggested by RS Connect see https://docs.rstudio.com/connect/cookbook/deploying/#creating-content
if ! test \( -e .rsc_content_guid \)
	# Send only required json fields to the server.
	set --local content_item '{"name": "TO_BE_REPLACED", "title": "TO_BE_REPLACED"}'
	# Replace placeholders with jq
	set --local content_item (echo $content_item | jq --arg title "$content_title" --arg name "$content_name" '. | .["title"]=$title | .["name"]=$name')
# 	echo "##################################################"
# 	echo "[DEBUG]: Content item to be uploaded: "
# 	echo $content_item
# 	echo "##################################################"
	set --local api_endpoint (string join '' "$CONNECT_SERVER" "$api_path" "content")
	set --local response_to_created_content (\
		curl --insecure --silent --show-error --location --max-redirs 0 --fail --request POST \
		--header "Authorization: Key $CONNECT_API_KEY" \
		--data-raw "$content_item" \
		$api_endpoint \
	)
	if ! test \( $status -eq 0 \) 
		echo "Content creation failed."
		clean_up $files_to_be_cleaned_on_error
		echo "Exiting..."
		exit 1
	end
	# Successfully created content
# 	echo "##################################################"
# 	echo "[DEBUG]: Response form server:"
# 	echo $response_to_created_content | jq '.'
# 	echo "##################################################"
	set --global content_guid (echo $response_to_created_content | jq --raw-output '.guid')
	set --global content_url (echo $response_to_created_content | jq --raw-output '.url')
	echo "Successfully created content item with GUID $content_guid."
	echo "Write to file .rsc_content_guid"
	echo $content_guid > .rsc_content_guid
	set --global files_to_be_cleaned_on_error $files_to_be_cleaned_on_error .rsc_content_guid
else
	echo "Reuse existing .rsc_content_guid file."
end
#}}}
# Upload bundle.tar.gz {{{
# For Details see https://docs.rstudio.com/connect/api/#post-/v1/experimental/content/{guid}/upload
# The Api endpoint is slightly different here
# It orientates towards https://github.com/rstudio/connect-api-deploy-shiny
set --local api_endpoint (string join '' "$CONNECT_SERVER" "$api_path" "content/" "$content_guid/" "bundles")
# echo "[DEBUG]: Server URL is $api_endpoint"
set --local response_to_uploaded_archive (\
	curl --insecure --silent --show-error --location --max-redirs 0 --fail --request POST \
	--header "Authorization: Key $CONNECT_API_KEY" \
	--data-binary @"$bundle_path" \
	$api_endpoint \
)
if ! test \( $status -eq 0 \) 
	set --local rsconnect_error_msg (echo $response_to_uploaded_archive | jq '.error')
	echo "##################################################"
	echo "Uploading bundle.tar.gz failed with response from server:"
	printf "	%s\n" $response_to_uploaded_archive
	echo "##################################################"
	clean_up $files_to_be_cleaned_on_error
	remove_content_item $content_guid
	echo "Exiting..."
	exit 1
end
set --global bundle_id (echo $response_to_uploaded_archive | jq --raw-output '.id')

echo "Successfully uploaded bundle.tar.gz and created deployment bundle $bundle_id"
#}}}
# Deploy deployment bundle {{{
# See also https://docs.rstudio.com/connect/api/#post-/v1/content/{guid}/deploy
# Start deployment task {{{

set --local data_deploy '{"bundle_id":"TO_BE_REPLACED"}'
set --local data_deploy (echo $data_deploy | jq --arg bid $bundle_id '. | .["bundle_id"]=$bid')
set --local api_endpoint (string join '' "$CONNECT_SERVER" "$api_path" "content/" "$content_guid/" "deploy")
echo "[DEBUG]: Data json to deploy is $data_deploy"
echo "[DEBUG]: Server api endpoint is $api_endpoint"
set --global response_to_starting_depl_task (\
	curl --insecure --silent --show-error --location --max-redirs 0 --fail --request POST \
		--header "Authorization: Key $CONNECT_API_KEY" \
		--data-raw "$data_deploy" \
		$api_endpoint \
)
if ! test \( $status -eq 0 \)
	echo "Starting deployment task failed."
	clean_up $files_to_be_cleaned_on_error
	remove_content_item $content_guid
	echo "Exiting..."
	exit 1
end
set --global deployment_task_id (echo $response_to_starting_depl_task | jq --raw-output '.task_id')
echo "Successfully started deployment task $deployment_task_id"

#}}}
# Poll deployment status until finished {{{
# For Details see https://docs.rstudio.com/connect/api/#get-/v1/tasks/{id}
set --global deploy_is_finished "false"
set --global code -1
set --global first 0
set --global counter 1
while test \( "$deploy_is_finished" = "false" \)
	# The URL needs to be composed separately, since fish otherwise interprets the "="-sign.
	set --local task_api_endpoint (string join '' "$CONNECT_SERVER" "__api__/v1/tasks/" "$deployment_task_id" "?wait=1&first=" "$first")
	set --local deployment_task_status (\
		curl --insecure --silent --location --max-redirs 0 --fail --request GET \
		--header "Authorization: Key $CONNECT_API_KEY" \
		"$task_api_endpoint"
		)
	set --global deploy_is_finished (echo $deployment_task_status | jq '.finished')
	set --global code (echo $deployment_task_status | jq '.code')
	set --global first (echo $deployment_task_status | jq '.last')
	echo "##################################################"
	echo "[DEBUG]: Poll No: $counter"
	echo "Deployment task $deployment_task_id:"
	printf "	%s\n" (echo $deployment_task_status | jq '.')
	echo "##################################################"
	echo ""

	if ! test \( $code -eq 0 \)
		 set --local rsconnect_error_msg (echo $deployment_task_status | jq '.error')
		 echo "##################################################"
		 echo "[Error]: There was a problem finishing the deployment task."
		 echo "Response from Server:"
		 printf "	%s\n" $rsconnect_error_msg
		 echo "##################################################"
		 clean_up $files_to_be_cleaned_on_error
		 remove_content_item $content_guid
		 echo "Exiting..."
		 exit 1
	end
end
echo "Deployment task finished successfully."
		 clean_up $files_to_be_cleaned_on_error
		 remove_content_item $content_guid
		 echo "Exiting..."
		 exit 1
# echo "Go to $content_url to see the results"
open -a Firefox $content_url

#}}}
#}}}
# Clean up and exit {{{

clean_up $files_to_be_cleaned_on_success
exit 0

#}}}
#}}}
