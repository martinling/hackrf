name: Bug Report 
description: Submit a bug report
title: "[Bug Report]: "
labels: ["bug report"]
body:
  - type: markdown
    attributes:
      value: |
        Thank you for taking the time to fill out this bug report!
  - type: dropdown
    id: issue type
    attributes: 
      label: What type of issue is this? 
      options:
        - transient - occurring only once
        - intermittent - occurring irregularly
        - permanent - occurring repepatedly
    validations:
      required: true
  - type: textarea
    id: issue
    attributes:
      label: What issue are you facing? 
      placeholder: Please describe what you have encountered
    validations:
      required: true
  - type: textarea
    id: reproduce issue
    attributes:
      label: What are the steps to reproduce this? 
      placeholder: Please provide the steps to reproduce this issue
    validations:
      required: true      
  - type: textarea
    id: logs
    attributes:
      label: Can you provide any logs? (output, errors, etc.)
      placeholder: Please provide any logs you might have that illustrate the issue
