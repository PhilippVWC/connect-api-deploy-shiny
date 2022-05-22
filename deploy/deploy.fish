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
# DEPENDENCIES: jq, curl
# Global variables {{{

# Initialize empty variable that containes the names of the files created at runtime
set --global files_to_be_cleaned_on_error
set --global files_to_be_cleaned_on_success
# Random number as a name for the content item to be deployed.
# The name field should not collide with other names and is 
# therefore created randomly.
set --global content_name (random)

#}}}
# function definitions {{{

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
	echo "	$files_missing" 
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

if ! test \( -e .rsc_content_guid \)
	set --local content_item '{
	  "access_type": "acl",
	  "connection_timeout": 3600,
	  "description": "...",
	  "idle_timeout": 5,
	  "init_timeout": 60,
	  "load_factor": 0.5,
	  "max_conns_per_process": 20,
	  "max_processes": 3,
	  "min_processes": 0,
	  "name": "TO_BE_REPLACED",
	  "read_timeout": 3600,
	  "run_as": "rstudio-connect",
	  "run_as_current_user": false,
	  "title": "TO_BE_REPLACED"
	}'
	set --local content_item (echo $content_item | jq --arg title "$content_title" --arg name "$content_name" '. | .["title"]=$title | .["name"]=$name')
	printf "%s\n" $content_item
	echo "$CONNECT_SERVER"__api__/v1/content
	set --local response_to_created_content (\
		curl --insecure --silent --show-error --location --max-redirs 0 --fail --request POST \
		--header "Authorization: Key $CONNECT_API_KEY" \
		--data-raw "$content_item" \
		"$CONNECT_SERVER"__api__/v1/content
	)
	if ! test \( $status -eq 0 \) 
		echo "Content creation failed."
		clean_up $files_to_be_cleaned_on_error
		echo "Exiting..."
		exit 1
	end
	# Successfully created content
	set --global content_guid (echo $response_to_created_content | jq .guid)
	echo "Successfully created content item with GUID $content_guid."
	echo "Write to file .rsc_content_guid"
	echo $content_guid > .rsc_content_guid
	set --global files_to_be_cleaned_on_error $files_to_be_cleaned_on_error .rsc_content_guid
else
	echo "Reuse existing .rsc_content_guid file."
end

#}}}
# Clean up and exit {{{

clean_up $files_to_be_cleaned_on_success
exit 0

#}}}
#}}}
