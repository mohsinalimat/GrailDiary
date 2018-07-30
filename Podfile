# Uncomment the next line to define a global platform for your project
# platform :ios, '9.0'

target 'CommonplaceBookApp' do
  # Comment the next line if you're not using Swift and don't want to use dynamic frameworks
  use_frameworks!

  platform :ios, '11.0'

  # Pods for remember
  pod 'CommonplaceBook', :path => '../CommonplaceBook'
  pod 'MiniMarkdown', :path => '../MiniMarkdown', :testspecs => ['Tests']
  pod 'MaterialComponents', :git => 'https://github.com/material-components/material-components-ios'
  pod 'textbundle-swift', :path => '../textbundle-swift', :testspecs => ['Tests']

  target 'CommonplaceBookAppTests' do
    inherit! :search_paths
    # Pods for testing
  end

  post_install do |installer|
    installer.pods_project.main_group.tab_width = '2';
    installer.pods_project.main_group.indent_width = '2';
  end
end
