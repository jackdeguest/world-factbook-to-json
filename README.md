# world-factbook-to-json

## What is does
* this simple per script will fetch the main page of the CIA World Factbook and from there get the list of countries to process from the drop down menu
* It will download each country page using the HTTP header If-Modified-Since comparing the last modification date to the one of the local cache file stored under the directory 'cache'. This directory is created if it does not already exist.
* it will then process each page following a structure identified as of March 2016 whereby sections are identified by h2 tags then followed by a div containing other divs with id 'field' for the categories, with class of 'category' but no id for sub-category and class of 'category_data' for category data. Multiple category data are layed out as paragraph and are concatenated using a double carriage return (\n\n)
* each set of data found for a country are added to a associative array (hash), itself stored as value to a hash key matching the 2 uppercase letter fo the country code (the one from the initial drop-down menu), which follows the GEC standard. More on this here: (https://www.cia.gov/library/publications/the-world-factbook/appendix/appendix-d.html)
* it also downloads the age pyramid for each country if available and stores it under the directory pyramid, which is created automatically if it does not already exist.
* After all countries have been processed, it outputs 2 json files:
- data.json containing all the data stored as a json data
- structure.json to reflect all the possible structure (section, category, sub-category) found while processing all the country file. This is designed to help decide how to organise a SQL database schema.

## How to use it
simply run the script ./scrap_factbook.pl 2>err.log > output.log

It will take a few minutes to complete. You may see error about fetching some pyramid file. That's because some image files do not exist.

## Dependencies
* WWW::Mechanize
* HTML::TreeBuilder
* Time::HiRes
* HTTP::Cookies
* HTTP::Date
* File::Basename
* JSON
* IO::File

## Copyright
* This is free code without guarantee of suitability of any kind.
