#!/usr/bin/env fish
# Readme {{{
# Deploy v. 1.0.0
#
# Create content in RStudio Connect with a given title. Does not prevent the
# creation of duplicate titles.
# 
# Run this script from the content root directory.
# }}}
# dependencies {{{
# - jq-1.6
# - curl-7.83.1
# - Rscript-4.1.2 and R-package "rsconnect" version >= 0.8.15
# - tar-3.5.1
# }}}
# Parse command line options {{{

# v/verbose
argparse 'v/verbose' 'i/interactive' 'h/help' -- $argv
or return
# make command line options global. Otherwise not usable later
# Change variable scope of option flags to global {{{

if test -n "$_flag_interactive"
	set --global _flag_interactive $_flag_interactive
	set --global _flag_i $_flag_i
end

if test -n "$_flag_verbose"
	set --global _flag_verbose $_flag_verbose
	set --global _flag_v $_flag_v
end

if test -n "$_flag_help"
	set --global _flag_help $_flag_help
	set --global _flag_h $_flag_h
end

#}}}

#}}}
# Global variables {{{

# Initialize empty variable that containes the names of the files created at runtime
set --global files_to_be_cleaned_on_error
set --global files_to_be_cleaned_on_success
set --global content_title $argv[1]
# Random number as a name for the content item to be deployed.
# The "name" field should not collide with other names for all content deployed by one user 
# and is therefore created randomly.
# See https://docs.rstudio.com/connect/cookbook/deploying/#creating-content for details.
set --global content_name (string join '' (random) (random))
set --global api_path "__api__/v1/content"

#}}}
# function definitions {{{

function show_help
	echo "##################################################################################"
	echo -e (string join ' ' "Usage: " "\e[33m" (status basename) "\e[36m[-h/--help] [-i/--interactive] [-v/--verbose]" "\e[32m<content-title>" "\e[0m")
	# printf "	Usage: %s [-h/--help] [-i/--interactive] [-v/--verbose] <content-title>\n" (status basename)
	echo "##################################################################################"
end
# echo_verbose {{{

function echo_verbose 
	if test -n "$_flag_verbose"
		echo $argv
	end
end

#}}}
# clean_up {{{

function clean_up
	echo_verbose "Clean up..."
	for file in $argv
		if test \( -e "$file" \) 
			rm -f $file
			echo_verbose "File $file removed."
		end
	end
end

#}}}
# remove_content_item {{{

function remove_content_item
	if test \( -n "$argv" \)
		set --local endpoint_delete_content (string join '' "$CONNECT_SERVER" "$api_path/" "$argv")
		echo_verbose "Removing content item $argv"
		set --local response_to_deleted_content (\
			curl --silent --insecure --show-error --location --max-redirs 0 --fail --request DELETE \
				--header "Authorization: Key $CONNECT_API_KEY" \
				"$endpoint_delete_content" \
				)
		if ! test \( $status -eq 0 \)
			set --local error_msg (echo $response_to_deleted_content | jq --raw-output '.error')
			echo_verbose "Deletion of content item $argv unsuccessful."
			echo_verbose "Message: "
			set_color yellow
			echo_verbose "	$error_msg"
			set_color normal
		else
			echo_verbose "Deletion of content item $argv successful."
		end
	end
end

#}}}

#}}}
# Checks in advance {{{
# check command line arguments {{{

if test -z "$argv" -o -n "$_flag_help"
	echo_verbose "Please provide a title for the content to be deployed: "
	show_help
	exit 1
else
	echo_verbose "##################################################"
	set_color brblue
	echo_verbose "Deploy content $content_title"
	set_color normal
	echo_verbose "##################################################"
end

#}}}
# check server environment variable {{{

# If the CONNECT_SERVER environment variable is not defined
# exit with a warning
# Syntax: the escaped paranthesis are optional. See also https://fishshell.com/docs/current/cmds/test.html#cmd-test
if ! test \( -n "$CONNECT_SERVER" \)
	echo_verbose "The CONNECT_SERVER environment variable is not defined. It defines"
	echo_verbose "the base URL of your RStudio Connect instance."
	echo_verbose 
	echo_verbose "    export CONNECT_SERVER='http://connect.company.com/'"
	exit 1
end


#}}}
# check api key environment variable {{{

if ! test \( -n "$CONNECT_API_KEY" \)
	echo_verbose "The CONNECT_API_KEY environment variable is not defined. It must contain"
	echo_verbose "an API key owned by a 'publisher' account in your RStudio Connect instance."
	echo_verbose
	echo_verbose "    export CONNECT_API_KEY='jIsDWwtuWWsRAwu0XoYpbyok2rlXfRWa'"
	exit 1
end

#}}}
# create app.R {{{

if ! test \( -e "app.R" \) 
	if test -n "$_flag_interactive"
		echo_verbose "The file app.R does not exist. It serves rsconnect as an entry point to the shiny app."
		echo_verbose "Create it?"
		set --global create_app_r_file (read --prompt-str "y/n?: " | string trim)
	else
		echo_verbose "Create file \"app.R\"..."
		set --global create_app_r_file "y"
	end
	if test \( "$create_app_r_file" = "y" \)
		printf "# Launch the ShinyApp (Do not remove this comment)\n#To deploy, run: rsconnect::deployApp()\n#Or use the blue button on top of this file\n\npkgload::load_all(export_all = FALSE, helpers = FALSE, attach_testthat = FALSE)\nrun_app()" > app.R
		set --global files_to_be_cleaned_on_error $files_to_be_cleaned_on_error app.R
		echo_verbose "File app.R created"
	else
		echo_verbose "Exiting..."
		exit 1
	end
else
	echo_verbose "Reuse existing file \"app.R\""
end

#}}}
# create manifest.json {{{

if ! test \( -e "manifest.json" \)
	if test -n "$_flag_interactive"
		echo_verbose "An RS Connect manifest file does not exist. This file is crucial for RS Connect to deploy the app."
		echo_verbose "Create it?"
		set --global create_manifest_file (read --prompt-str "y/n: " | string trim)
	else
		echo_verbose "Create manifest.json..."
		set --global create_manifest_file "y"
	end
	if test \( $create_manifest_file = "y" \) 
		Rscript --vanilla -e "rsconnect::writeManifest()" > /dev/null 2>error_msgs_rscript.tmp
		set --global files_to_be_cleaned_on_error $files_to_be_cleaned_on_error manifest.json
		# Did Rscript print out any warnings or errors? If so, exit.
		if test \( (cat error_msgs_rscript.tmp | wc -l | string trim) != "0" \)
			echo_verbose "A manifest file could not be created without errors."
			clean_up $files_to_be_cleaned_on_error
			echo_verbose "Exiting..."
			exit 1
		else
			echo_verbose "Manifest file manifest.json created"
			if test \( -e error_msgs_rscript.tmp \) 
				rm -f error_msgs_rscript.tmp
			end
		end
	end
else
	echo_verbose "Reuse existing file \"manifest.json\""
end

#}}}
#}}}
# Programm {{{
# Create archive file {{{

set --local bundle_path "bundle.tar.gz"
set --local files_to_deploy_all app.R manifest.json R man DESCRIPTION NAMESPACE .Rbuildignore .Renviron man-roxygen README.md data-raw data inst
set --global files_to_deploy
set --global files_missing
echo_verbose "Zip directory content to $bundle_path:"
for file in $files_to_deploy_all
	if test \( -e "$file" \) 
		set --global files_to_deploy $files_to_deploy $file
	else
		set --global files_missing $files_missing $file
	end
end
if test \( -n "$files_missing" \)
	if test -n "$_flag_interactive"
		echo_verbose "The files:"
		set_color yellow
		echo_verbose "	$files_missing" 
		set_color normal
		echo_verbose "are not contained in the currend working directory."
		echo_verbose "Continue? "
		set --global create_archive_file (read --prompt-str "y/n: " | string trim)
	else
		set --global create_archive_file "y"
	end
	if test \( $create_archive_file != "y" \)
		clean_up $files_to_be_cleaned_on_error
		echo_verbose "Exiting..."
		exit 1
	end
	tar czf $bundle_path $files_to_deploy
	echo_verbose "Archive file created."
	set --global files_to_be_cleaned_on_success "$files_to_be_cleaned_on_success" "bundle.tar.gz"
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
	set --local api_endpoint (string join '' "$CONNECT_SERVER" "$api_path")
	echo "[DEBUG]: Create content at $api_endpoint"
	echo "[DEBUG]: data $content_item"
	set --local response_to_created_content (\
		curl --insecure --silent --show-error --location --max-redirs 0 --fail --request POST \
		--header "Authorization: Key $CONNECT_API_KEY" \
		--data-raw "$content_item" \
		"$api_endpoint" \
	)
	if ! test \( $status -eq 0 \) 
		echo_verbose "Content creation failed."
		clean_up $files_to_be_cleaned_on_error
		echo_verbose "Exiting..."
		exit 1
	end
	set --global content_guid (echo $response_to_created_content | jq --raw-output '.guid')
	set_color yellow
	echo_verbose "Successfully created content item with GUID $content_guid."
	set_color normal
	echo_verbose "[DEBUG]: Response form server:"
	echo_verbose "$response_to_created_content" | jq '.'
	echo_verbose "Persist content guid $content_guid to file .rsc_content_guid"
	echo $content_guid > .rsc_content_guid
	set --global files_to_be_cleaned_on_error $files_to_be_cleaned_on_error .rsc_content_guid
else
	echo_verbose "Reuse existing .rsc_content_guid file with content guid: "
	set --global content_guid (cat .rsc_content_guid | string trim)
	set_color yellow
	echo_verbose " $content_guid"
	set_color normal
end

#}}}
# Upload bundle.tar.gz {{{
# For Details see https://docs.rstudio.com/connect/api/#post-/v1/experimental/content/{guid}/upload
# The Api endpoint is slightly different here
# It orientates towards https://github.com/rstudio/connect-api-deploy-shiny
set --local api_endpoint (string join '' "$CONNECT_SERVER" "$api_path/" "$content_guid/" "bundles")
echo_verbose "[DEBUG]: Upload zip archive to $api_endpoint"
set --local response_to_uploaded_archive (\
	curl --insecure --silent --show-error --location --max-redirs 0 --fail --request POST \
	--header "Authorization: Key $CONNECT_API_KEY" \
	--data-binary @"$bundle_path" \
	"$api_endpoint" \
)
if ! test \( $status -eq 0 \) 
	set --local rsconnect_error_msg (echo $response_to_uploaded_archive | jq '.error')
	echo_verbose "##################################################"
	echo_verbose "Uploading bundle.tar.gz failed with response from server:"
	printf "	%s\n" $response_to_uploaded_archive
	echo_verbose "##################################################"
	clean_up $files_to_be_cleaned_on_error
	remove_content_item $content_guid
	echo_verbose "Exiting..."
	exit 1
end
set --global bundle_id (echo $response_to_uploaded_archive | jq --raw-output '.id')

set_color yellow
echo_verbose "Successfully uploaded bundle.tar.gz and created deployment bundle $bundle_id"
set_color normal
#}}}
# Deploy deployment bundle {{{
# See also https://docs.rstudio.com/connect/api/#post-/v1/content/{guid}/deploy
# Start deployment task {{{

set --local data_deploy '{"bundle_id":"TO_BE_REPLACED"}'
set --local data_deploy (echo $data_deploy | jq --arg bid $bundle_id '. | .["bundle_id"]=$bid')
set --local api_endpoint (string join '' "$CONNECT_SERVER" "$api_path/" "$content_guid/" "deploy")
echo_verbose "[DEBUG]: data \"json\" to deploy is $data_deploy"
echo_verbose "[DEBUG]: deployment api endpoint is $api_endpoint"
set --global response_to_starting_depl_task (\
	curl --insecure --silent --show-error --location --max-redirs 0 --fail --request POST \
		--header "Authorization: Key $CONNECT_API_KEY" \
		--data-raw "$data_deploy" \
		"$api_endpoint" \
)
if ! test \( $status -eq 0 \)
	echo_verbose "Starting deployment task failed."
	clean_up $files_to_be_cleaned_on_error
	remove_content_item $content_guid
	echo_verbose "Exiting..."
	exit 1
end
set --global deployment_task_id (echo $response_to_starting_depl_task | jq --raw-output '.task_id')
set_color yellow
echo_verbose "Successfully started deployment task $deployment_task_id"
set_color normal

#}}}
# Poll deployment status until finished {{{ For Details see https://docs.rstudio.com/connect/api/#get-/v1/tasks/{id}
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
	set_color yellow
	echo_verbose "[DEBUG]: Poll No: $counter"
	set_color normal
	echo_verbose "Deployment task $deployment_task_id:"
	echo_verbose "$deployment_task_status" | jq '.'
	echo_verbose ""
	set --global counter (math $counter + 1)

	if ! test \( $code -eq 0 \)
		 set --local rsconnect_error_msg (echo $deployment_task_status | jq '.error')
		 echo_verbose "##################################################"
		 echo_verbose "[Error]: There was a problem finishing the deployment task."
		 echo_verbose "Response from Server:"
		 printf "	%s\n" "$rsconnect_error_msg"
		 echo_verbose "##################################################"
		 clean_up $files_to_be_cleaned_on_error
		 remove_content_item $content_guid
		 echo_verbose "Exiting..."
		 exit 1
	end
end
set_color yellow
echo_verbose "Deployment task finished successfully."
set_color normal

#}}}
#}}}
# Get content details {{{

set --local api_endpoint (string join '' "$CONNECT_SERVER" "$api_path/" "$content_guid")
set --local content_details (\
	curl --insecure --silent --show-error --location --max-redirs 0 --fail --request GET \
		--header "Authorization: Key $CONNECT_API_KEY" \
		"$api_endpoint"
)
echo_verbose "Content Details:"
echo_verbose "$content_details" | jq '.'

if ! test $status -eq 0
	echo "Retrieval of content details failed with error message:"
	echo "##################################################"
	printf "	%s\n" $content_details
	echo "##################################################"
	clean_up $files_to_be_cleaned_on_error
	remove_content_item $content_guid
	echo "Exiting..."
	exit 1
end
set --local content_url (echo $content_details | jq '.content_url')

#}}}
# Clean up and exit {{{

echo "URL to $content_title: "
set_color yellow
echo "	$content_url"
set_color normal
clean_up $files_to_be_cleaned_on_success
exit 0

#}}}
#}}}
