//
//  NSObject+AutomagicCoding.m
//  AutomagicCoding
//
//  Created by Stepan Generalov on 31.08.11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "NSObject+AutomagicCoding.h"


#define NSOBJECT_AUTOMAGICCODING_CLASSNAMEKEY @"class"

@implementation NSObject (AutomagicCoding)

+ (BOOL) isAutomagicCodingEnabled
{
    return NO;
}

#pragma mark Decode/Create/Init

+ (id) objectWithDictionaryRepresentation: (NSDictionary *) aDict
{
    if (![aDict isKindOfClass:[NSDictionary class]])
        return nil;
    
    NSString *className = [aDict objectForKey: NSOBJECT_AUTOMAGICCODING_CLASSNAMEKEY];
    if( ![className isKindOfClass:[NSString class]] )
        return nil;
    
    Class rClass = NSClassFromString(className);
    if ( rClass && [rClass instancesRespondToSelector:@selector(initWithDictionaryRepresentation:) ] )
    {
        id instance = [[[rClass alloc] initWithDictionaryRepresentation: aDict] autorelease];
        return instance;
    }
    
    return nil;
}

- (id) initWithDictionaryRepresentation: (NSDictionary *) aDict
{
    if ( (self =  [self init]) )
    {
        NSArray *keysForValues = [self keysForValuesInDictionaryRepresentation];
        for (NSString *key in keysForValues)
        {
            id value = [aDict valueForKey: key];
            
            AMCObjectFieldType fieldType = [self fieldTypeForValueWithKey: key];
            objc_property_t property = class_getProperty([self class], [key cStringUsingEncoding:NSUTF8StringEncoding]);
            id class = AMCPropertyClass(property);
            value = AMCFieldValueFromEncodedStateAndFieldType(value, fieldType, class);            
                                   
            [self setValue:value forKey: key];
        }
        
    }
    return self;
}

#pragma mark Encode/Save

- (NSDictionary *) dictionaryRepresentation
{
    NSArray *keysForValues = [self keysForValuesInDictionaryRepresentation];
    NSMutableDictionary *aDict = [NSMutableDictionary dictionaryWithCapacity:[keysForValues count] + 1];
       
    for (NSString *key in keysForValues)
    {
        id value = [self valueForKey: key];
        
        
        AMCObjectFieldType fieldType = [self fieldTypeForValueWithKey: key];            
        switch (fieldType) 
        {
                
            // Object as it's representation - create new.
            case kAMCObjectFieldTypeCustom:
            {
                if ([value respondsToSelector:@selector(dictionaryRepresentation)])
                    value = [(NSObject *) value dictionaryRepresentation];
            }
            break;
                
                
                // Scalar or struct - simply use KVC.
            case kAMCObjectFieldTypeSimple:
                break;                    
            default:
                break;
        }
        
        // Scalar or struct - simply use KVC.                       
        [aDict setValue:value forKey: key];
    }
    
    [aDict setValue:[self className] forKey: NSOBJECT_AUTOMAGICCODING_CLASSNAMEKEY];
    
    return aDict;
}


#pragma Info for Serialization

- (NSArray *) keysForValuesInDictionaryRepresentation
{
    id class = [self class];
    
    // Use objc runtime to get all properties and return their names.
    unsigned int outCount;
    objc_property_t *properties = class_copyPropertyList(class, &outCount);
    NSMutableArray *array = [NSMutableArray arrayWithCapacity: outCount];
    for (int i = 0; i < outCount; ++i)
    {
        objc_property_t curProperty = properties[i];
        const char *name = property_getName(curProperty);
        
        NSString *propertyKey = [NSString stringWithCString:name encoding:NSUTF8StringEncoding];
        [array addObject: propertyKey];        
    }
    
    return array;
}

- (AMCObjectFieldType) fieldTypeForValueWithKey: (NSString *) aKey
{
    // isAutomagicCodingEnabled == YES? Then it's custom object.
    objc_property_t property = class_getProperty([self class], [aKey cStringUsingEncoding:NSUTF8StringEncoding]);
    id class = AMCPropertyClass(property);
    
    if ([class isAutomagicCodingEnabled])
        return kAMCObjectFieldTypeCustom;
    
    // Is it ordered collection?
    if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCArrayProtocol) ) )
    {
        // Mutable?
        if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCArrayMutableProtocol) ) )
            return kAMCObjectFieldTypeCollectionArrayMutable;
        
        // Not Mutable.
        return kAMCObjectFieldTypeCollectionArray;
    }
    
    // Is it hash collection?
    if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCHashProtocol) ) )
    {
        // Mutable?
        if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCHashMutableProtocol) ) )
            return kAMCObjectFieldTypeCollectionHashMutable;
        
        // Not Mutable.
        return kAMCObjectFieldTypeCollectionHash;
    }
    
    
    return kAMCObjectFieldTypeSimple;
}

@end


#pragma mark Helper Functions

id AMCPropertyClass (objc_property_t property)
{
    if (!property)
        return nil;
    
    const char *attributes = property_getAttributes(property);
    char *classNameCString = strstr(attributes, "@\"");
    if ( classNameCString )
    {
        classNameCString += 2; //< skip @" substring
        NSString *classNameString = [NSString stringWithCString:classNameCString encoding:NSUTF8StringEncoding];
        NSRange range = [classNameString rangeOfString:@"\""];
        
        classNameString = [classNameString substringToIndex: range.location];
        
        id class = NSClassFromString(classNameString);
        return class;
    }
    
    return nil;
}

BOOL classInstancesRespondsToAllSelectorsInProtocol(id class, Protocol *p )
{
    unsigned int outCount = 0;
    struct objc_method_description *methods = NULL;
    
    methods = protocol_copyMethodDescriptionList( p, YES, YES, &outCount);
    
    for (unsigned int i = 0; i < outCount; ++i)
    {
        SEL selector = methods[i].name;
        if (![class instancesRespondToSelector: selector])
            return NO;
    }
        
    
    return YES;
}

id AMCFieldValueFromEncodedStateAndFieldType (id value, AMCObjectFieldType fieldType, id collectionClass )
{
    switch (fieldType) 
    {
            
        // Object as it's representation - create new.
        case kAMCObjectFieldTypeCustom:
        {
            id object = [NSObject objectWithDictionaryRepresentation: (NSDictionary *) value];
            
            if (object)
                value = object;
        }
        break;
            
            
        case kAMCObjectFieldTypeCollectionArray:
        case kAMCObjectFieldTypeCollectionArrayMutable:
        {
            // Create temporary array of all objects in collection.
            id <AMCArrayProtocol> srcCollection = (id <AMCArrayProtocol> ) value;
            NSMutableArray *dstCollection = [NSMutableArray arrayWithCapacity:[srcCollection count]];
            for (unsigned int i = 0; i < [srcCollection count]; ++i)
            {
                id curEncodedObjectInCollection = [srcCollection objectAtIndex: i];
                id curDecodedObjectInCollection = AMCFieldValueFromEncodedStateAndFieldType( curEncodedObjectInCollection, AMCFieldTypeForObject(curEncodedObjectInCollection), nil );
                [dstCollection addObject: curDecodedObjectInCollection];
            }
            
            // Get Collection Array Class from property and create object
            id class = collectionClass;
            if (!collectionClass)
            {
                if (kAMCObjectFieldTypeCollectionArray)
                    class = [NSArray class];
                else
                    class = [NSMutableArray class];
            }
            
            id <AMCArrayProtocol> object = (id <AMCArrayProtocol> )[class alloc];
            [object initWithArray: dstCollection];
            
            if (object)
                value = object;
        }
            break;
            
        case kAMCObjectFieldTypeCollectionHash:
        case kAMCObjectFieldTypeCollectionHashMutable:
        {
            // Create temporary array of all objects in collection.
            NSObject <AMCHashProtocol> *srcCollection = (NSObject <AMCHashProtocol> *) value;
            NSMutableDictionary *dstCollection = [NSMutableDictionary dictionaryWithCapacity:[srcCollection count]];
            for (NSString *curKey in [srcCollection allKeys])
            {
                id curEncodedObjectInCollection = [srcCollection valueForKey: curKey];
                id curDecodedObjectInCollection = AMCFieldValueFromEncodedStateAndFieldType( curEncodedObjectInCollection, AMCFieldTypeForObject(curEncodedObjectInCollection), nil );
                [dstCollection setObject: curDecodedObjectInCollection forKey: curKey];
            }
            
            // Get Collection Array Class from property and create object
            id class = collectionClass;
            if (!collectionClass)
            {
                if (kAMCObjectFieldTypeCollectionArray)
                    class = [NSDictionary class];
                else
                    class = [NSMutableDictionary class];
            }
            
            id <AMCHashProtocol> object = (id <AMCHashProtocol> )[class alloc];
            [object initWithDictionary: dstCollection];
            
            if (object)
                value = object;
        }            break;     
            
            // Scalar or struct - simply use KVC.
        case kAMCObjectFieldTypeSimple:
            break;                    
        default:
            break;
    }
    
    return value;
}

AMCObjectFieldType AMCFieldTypeForObject(id object)
{    
    id class = [object class];
    
    // Is it ordered collection?
    if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCArrayProtocol) ) )
    {
        // Mutable?
        if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCArrayMutableProtocol) ) )
            return kAMCObjectFieldTypeCollectionArrayMutable;
        
        // Not Mutable.
        return kAMCObjectFieldTypeCollectionArray;
    }
    
    // Is it hash collection?
    if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCHashProtocol) ) )
    {
        
        // Maybe it's custom object encoded in NSDictionary?
        if ([object respondsToSelector:@selector(objectForKey:)])
        {
            NSString *className = [object objectForKey:NSOBJECT_AUTOMAGICCODING_CLASSNAMEKEY];
            if ([className isKindOfClass:[NSString class]])
            {
                id encodedObjectClass = NSClassFromString(className);
                
                if ([encodedObjectClass isAutomagicCodingEnabled])
                    return kAMCObjectFieldTypeCustom;
            }
        }        
        
        // Mutable?
        if ( classInstancesRespondsToAllSelectorsInProtocol(class, @protocol(AMCHashMutableProtocol) ) )
            return kAMCObjectFieldTypeCollectionHashMutable;
        
        // Not Mutable.
        return kAMCObjectFieldTypeCollectionHash;
    }
    
    
    return kAMCObjectFieldTypeSimple;
}








