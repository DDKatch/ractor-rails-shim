# frozen_string_literal: true

# Backward-compatibility redirect. The require hub moved to loader.rb
# (POODR §1 SRP — one file, one job). This file exists so that any code
# doing `require "ractor_rails_shim/patches"` still works.

require_relative "loader"
