# Octocatalog-diff Onceover plugin

This plugin adds the `onceover run diff` command to onceover. Instead of testing that all if your catalogs compile, it compiles two versions of each catalog and returns you the differences. This is great for ensuring that changed that you were intending to make have had the desired effect and scope.

Kudos to Kevin and the team at GitHub for actually building [octocatalog-diff](https://github.com/github/octocatalog-diff)!

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'onceover-octocatalog-diff'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install onceover-octocatalog-diff

## Usage

`onceover run diff`

All config follows the normal [onceover](https://github.com/dylanratcliffe/onceover) configuration.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/dylanratcliffe/onceover-octocatalog-diff.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
